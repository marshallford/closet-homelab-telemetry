# Cooling a closet homelab

My homelab lives on a single shelf in an apartment coat closet with no airflow. I added two USB fans and pointed them across the gear.

I wanted to know whether they actually helped, which meant measuring temperatures before and after each change. This repo contains the setup I used: an OpenTelemetry (OTel) Collector on a Proxmox node scraping Node Exporter over loopback, a second collector alongside Prometheus and Grafana on my workstation, dashboards generated from Jsonnet, and scripts to mark changes and compare the windows on either side.

## The coat closet

There is network gear in there too, so it doubles as a network closet. The setup is deliberately small; the rest of the lab is in storage until there is room for it.

![An HP Elite Mini, an Apple TV, a switch, a router and an access point on a closet shelf, with two 120mm fans blowing across them](docs/images/closet.jpg)

What's in there:

* HP Elite Mini 805 G8, Proxmox node
* Dynalink AX3600 running OpenWrt
* NETGEAR GS305P
* UAP-AC-PRO
* Apple TV 4K, for Home Assistant's HomeKit Bridge

An SLZB-MR2 out in the living room hangs off the switch too, powered over PoE through the patch panel.

It gets warm.

A rack and/or proper ducting is not practical in an apartment, so I tried the simpler option: point a couple of fans across the shelf. The idea came from [this home lab tour](https://www.youtube.com/watch?v=vktLEFH7t7c) by KTZ Systems, where the host mentions keeping small fans on top of hot-running gear, including a fan added after an SFP+ NIC overheated and died.

I spent longer choosing between fans than the problem deserved. I looked at Noctua first, but a bare case fan still needs somewhere to sit, and an NF-A14 5V felt expensive for this job. I ended up with an AC Infinity MULTIFAN S7: two 120mm USB-powered fans with rubber feet and an inline speed controller.

The Elite Mini runs Proxmox VE with a handful of VMs. It is the busiest device in the closet and the one whose temperature I care about, so it is what this repo instruments and what the graphs below show. The OpenWrt router could expose metrics too, but the switch is unmanaged and the rest are closed boxes.

## The result

| change        |     CPU temp |
| ------------- | -----------: |
| off -> low    | **-4.40 °C** |
| low -> off    |     +4.49 °C |
| off -> medium | **-4.78 °C** |
| medium -> off |     +5.13 °C |
| off -> high   | **-4.51 °C** |

![Eight hwmon readings over nine hours: the CPU line near 67 °C dips to about 62 °C three times, once for each fan speed](docs/images/host-overview-temperature-by-sensor.png)

The fans take about 4.5 °C off the CPU. Fan speed barely matters: the drops were 4.40 °C on low, 4.78 °C on medium, and 4.51 °C on high. Those differences are comparable to the roughly ±0.3 °C baseline drift, and medium beat high by 0.27 °C despite moving less air, which suggests the difference between speeds is mostly noise.

Low and medium were switched off again after each run. Temperatures rose by 4.49 °C and 5.13 °C, respectively, closely matching the drops when the fans were switched on. That makes the effect much more likely to be the fans than a change in room temperature.

Two controls also held: CPU busy was flat across every comparison window, and the power rail stayed within ±0.7 W. The temperature change therefore tracks the cooling, not a workload change.

## Architecture

Answering one question about a closet turned into a general OpenTelemetry metrics pipeline. Temperature is just what I happened to be measuring. The same pipeline covers CPU, memory, disks, and network on Linux hosts. Proxmox adds node, guest, and storage metrics; the Proxmox-specific layer is only two transform statements and one dashboard. Anything else that speaks OTLP and already follows the conventions can join without source-specific plumbing.

```text
Proxmox node(s)
    |- OTel Collector ....... host + hwmon metrics .. OTLP/gRPC -> :4317 -.
    |      `- Node Exporter on loopback, scraped locally                  |
    `- PVE metric server .... node + guest metrics .. OTLP/HTTP -> :4318 -+
                .---------------------------------------------------------'
                |
                v
Workstation (containers)
    `- OTel Collector ... remote write -> Prometheus -> Grafana
```

The stack runs on a workstation rather than the machine it watches. Running it on the node would add heat and load, potentially throwing off the measurements. The node collector and PVE metric server push metrics, so nodes do not need to expose remotely reachable monitoring ports; Node Exporter listens only on loopback.

Three sources feed the pipeline:

* **PVE metric server.** Proxmox VE 9 ships an OpenTelemetry metric server, so node, VM, container, and storage metrics need no separate exporter or API token. It is configured once for the datacenter and sends OTLP/HTTP directly to the central collector.
* **OTel Collector.** The collector on each node uses the `host_metrics` receiver for CPU, load, memory, paging, disk, filesystem, network, process-count, and uptime metrics. This provides OS-level detail that the PVE metric server does not expose.
* **Node Exporter.** The `host_metrics` receiver has no temperature scraper, so Node Exporter's `hwmon` collector provides temperature sensors and power draw. The cooling measurements above come from those readings. Node Exporter is bound to loopback and scraped by the node collector over `127.0.0.1`.

The last two sources overlap, so the Node Exporter collectors that `host_metrics` already covers are disabled: cpu, loadavg, meminfo, diskstats, filesystem, netdev, stat, and vmstat. Leaving them enabled would duplicate the same host metrics under a second naming scheme. The `systemd` collector is disabled for a different reason. It emits several metrics per unit, and the number of units can grow with guests on a hypervisor, so it can dominate the series count. The `time` collector is disabled separately because its wall-clock, timezone, and clocksource metrics are not used here. What remains is mostly data `host_metrics` cannot provide, such as temperatures, power draw, and CPU frequency.

Metrics from all three sources reach the central collector over OTLP and leave it as a single remote-write stream. The Prometheus server itself has no scrape jobs.

## The collector pipeline

### Where configuration lives

The node collector handles what has to happen on the node: declaring its hostname and machine ID and scraping Node Exporter over loopback. Most naming, filtering, and limits live in the central collector, so node configs stay identical and rarely need changing.

Every metric passes through the central collector before storage. The pipeline does three jobs, in order:

* **Constrain.** Keep the collector itself within resource limits as node and workload growth increases metric volume. `memory_limiter` runs first so that backpressure reaches the receivers. It returns non-permanent errors upstream while heap allocation remains above its soft limit.
* **Admit.** Decide what is worth storing before spending effort on it. Example: the Prometheus receiver generates scrape metadata alongside the Node Exporter metrics.
* **Normalize.** Rewrite vocabularies toward semantic conventions and reconcile sources that describe the same thing under different names.

Transform mistakes can be quiet. A condition that matches nothing is not an error, so it does nothing and logs nothing. With `error_mode: ignore`, execution errors are logged and processing continues with the next statement rather than stopping the pipeline. New transforms should therefore be checked against real data rather than assumed to have applied.

### Normalizing toward semantic conventions

`host_metrics` is the only source here that already uses the OpenTelemetry system metric vocabulary. Node Exporter and the PVE metric server each use their own vocabularies, which the pipeline pulls toward the OpenTelemetry semantic conventions.

Three rules cover most of the normalization:

* **A host is not a service.** `service.*` identifies a service, not a host. The Prometheus receiver maps its scrape job to `service.name`, so the node collector removes that attribute. Sources that describe themselves, including PVE and the collectors, keep theirs.
* **Host identity.** A node declares its own `host.name` and `host.id`, plus a `service.instance.id` derived from its machine ID. That last one is the exception to the rule above: it is what the OTLP-to-Prometheus mapping turns into `instance`, and the machine ID keeps that label stable across restarts. PVE cannot be configured this way, so the central collector copies `proxmox.node` into `host.name`. That is what lets PVE metrics join host metrics.
* **Hardware sensors.** Only temperatures are normalized. `node_hwmon_temp_celsius{chip,sensor}` becomes `hw.temperature{hw.id,hw.parent}`. The matching `min`, `max`, `crit`, and `lcrit` metrics become `hw.temperature.limit` with an `hw.limit_type`. Everything else reported by hwmon keeps its upstream name.

#### Finer details

`hw.power` is not emitted. It requires `hw.type`, whose values identify a component such as `cpu`, `gpu`, or `power_supply`, but hwmon does not reliably say which component a power rail measures. On an integrated GPU, for example, the `amdgpu` rail can include CPU draw. `hw.host.power` is for the entire physical host, which does not fit a single rail either. `node_hwmon_power_watt` therefore keeps its original name, along with `chip` and `sensor`, rather than making a claim the source cannot support.

`hw.name` and `hw.sensor_location` are left unset for a similar reason. The driver name and sensor label live in `node_hwmon_chip_names` and `node_hwmon_sensor_label`, but the transform processor cannot read attributes from another metric. Both attributes are Recommended rather than Required, so leaving them absent is better than inventing them. The info metrics are retained, so those names can still be recovered at query time. For example, to add the sensor label:

```promql
node_hwmon_power_watt * on(host_name,chip,sensor) group_left(label) node_hwmon_sensor_label
```

A proposed [native hwmon scraper](https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/50396) reads the driver name and sensor label from sysfs alongside the measurements and populates both attributes directly. The transforms above are scoped to `node_hwmon_temp_*`, so native `hw.temperature` metrics will pass through untouched if that scraper lands.

Host metrics deliberately have no `job` label. Neither source supplies a `service.name`, which is what the OTLP-to-Prometheus mapping uses for `job`. How host metrics should identify themselves to Prometheus is an open question upstream, tracked in [contrib#46207](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/46207).

Other hwmon sensors are left alone. `hw.voltage` has a convention but is not normalized here; there is no `hw.current` convention; and normalizing `hw.status` would require synthesizing one data point per state from a single reading, which this transform does not do.

Everything else keeps its upstream name. `proxmox_vm_*`, ZFS, PSI, and the remaining Node Exporter-specific metrics are not normalized here. The relevant system and hardware conventions are still Development, and PSI is only a [proposal](https://github.com/open-telemetry/semantic-conventions/issues/2995), so the transform set stays narrow rather than guessing at unstable or nonexistent mappings.

### Watching the collectors themselves

The node collectors and central collector report their own health: data points accepted per receiver, data points sent or failed per exporter, queue depth, and memory use. Without that telemetry, a collector that stops forwarding can look the same as a quiet host.

A collector's internal telemetry is produced by its service layer rather than a receiver, so it does not automatically pass through that collector's own pipeline. Each collector therefore exports its telemetry over OTLP instead of exposing a port for something else to scrape. Node collectors send theirs to the central collector. The central collector loops its own telemetry back through its OTLP receiver.

On a node, the `resource_detection` processor runs only in the metrics pipeline, so it does not touch self-telemetry. The node collector instead sets `host.name` and `host.id` on its own metrics from environment variables populated by systemd with `%H` and `%m`.

Useful signals include `otelcol_exporter_sent_metric_points_total`, where a flat line on a node collector means it has stopped forwarding; `otelcol_exporter_queue_size` against `otelcol_exporter_queue_capacity` for backpressure; and `otelcol_process_runtime_heap_alloc_bytes` against the configured `memory_limiter` limits. Failure counters also exist but may be absent until something fails, so do not rely on them being present on a healthy stack.

Node Exporter is the exception. Its own process metrics describe the exporter rather than the machine, so `--web.disable-exporter-metrics` drops the `go_*`, `process_*`, and `promhttp_*` families at the source, and `filter/scaffolding` drops the scrape's own bookkeeping, `node_scrape_collector_*` and `scrape_*`, at the central collector. `up` is kept: one series per target, reporting whether the scrape succeeded.

## Querying

In this stack, the Prometheus remote-write path translates OTLP names on the way into Prometheus: dots become underscores and unit suffixes are appended. `host.name` becomes `host_name`, and `system.cpu.time` becomes `system_cpu_time_seconds_total`. Resource attributes land on every series rather than only on `target_info`, because the exporter is configured with `resource_constant_labels: included: ["*"]`. Confirm names in the metric browser rather than assuming them.

```promql
max by (host_name) (hw_temperature_celsius)
sum by (state) (system_memory_usage_bytes{host_name="..."})
```

PVE and host metrics share `host.name`, which is enough to join guest and host series in this setup. The other resource attributes differ: host metrics also carry `host.id` and `os.type`, while PVE metrics do not. Queries filtered by `host_id` or `os_type` therefore exclude PVE series.

Use `host_name` as the host key when combining sources. Host metrics have no `job` label. PVE declares a `service.name`, which becomes both its `job` and a `service_name` label, next to `service_version`.

## Dashboards

Two dashboards are provisioned. **Host Overview** covers OS-level metrics and hwmon sensors:

![Host Overview: a row of stat panels across the top, then time series panels grouped into compute, thermal, and storage and network rows](docs/images/host-overview.png)

**Proxmox Overview** covers node, guest, and storage state:

![Proxmox Overview: node stat panels across the top, then time series panels grouped into guests, guest I/O, and node and storage rows](docs/images/proxmox-overview.png)

Both dashboards appear on first start. The Prometheus data source is provisioned from a file, so a fresh Grafana volume needs no manual setup.

The dashboards are generated rather than hand-edited. Their source is [grafonnet](https://github.com/grafana/grafonnet) Jsonnet under `dashboards/`, rendered into the JSON Grafana reads:

```shell
make dashboards    # dashboards/*.jsonnet -> dashboards/rendered/*.json
make fmt/jsonnet   # format the jsonnet
make lint/jsonnet  # lint the jsonnet
```

The Jsonnet tooling runs in the `grafana/tanka` container, so nothing needs to be installed locally.

`dashboards/rendered/` is bind-mounted into Grafana and polled every 15 seconds, so a re-render appears without a restart. It is gitignored along with `dashboards/vendor/`; both are generated.

Dashboards are marked non-editable and `allowUiUpdates` is disabled, so the UI cannot drift from the source. Change the Jsonnet instead.

The dashboard images in this README come from [grafana-image-renderer](https://github.com/grafana/grafana-image-renderer), which runs as part of the stack. Whole dashboards, plus any panel whose title matches `RENDER_PANELS`, are written to `docs/images/`:

```shell
make screenshots RENDER_FROM=now-6h RENDER_TO=now
```

## Measuring a change

Changes are recorded as Grafana annotations tagged `fan`. The base `fan` tag is added automatically; `ANNOTATION_TAGS` carries the additional `state:` and `speed:` tags. Host Overview draws a line across every panel for each annotation with both `fan` and a `state:` tag: blue for `state:on`, orange for `state:off`.

```shell
make annotate ANNOTATION="fans, off -> medium" ANNOTATION_TAGS="state:on speed:medium"
make unannotate                              # delete every annotation tagged fan
```

`ANNOTATION_AT` accepts anything GNU `date -d` can parse, so changes can also be recorded after the fact:

```shell
make annotate ANNOTATION="fans, medium -> off" \
    ANNOTATION_TAGS="state:off speed:medium" \
    ANNOTATION_AT="1:46:00pm"
```

On a `state:off` annotation, `speed:` names the speed being left, not a speed still running. This keeps the off transition associated with the speed that produced it.

`make compare` searches only for the base `fan` tag, which is present on every annotation. It takes one window before the annotation and one after it, averages three metrics over each window, and prints both averages and their difference:

* **temperature (C):** the sensor named by `COMPARE_SENSOR`
* **power (W):** the hwmon power sensor named by `COMPARE_POWER`
* **cpu busy:** the share of CPU time that is not idle

The power rail and CPU busy act as controls. A temperature drop is only meaningful when both remain stable, since lower power or CPU usage may simply mean the machine is doing less work.

`COMPARE_HOST`, `COMPARE_SENSOR`, and `COMPARE_POWER` are selected automatically when only one option exists. Otherwise, they must be specified. If a required value is omitted, `make compare` lists the available options. Each run also prints the values used so they can be copied into a later command.

Temperature sensors are identified by their normalized `hw.id`. Power sensors use the retained raw hwmon chip and sensor names. The same sensor is read in both windows, so before and after always refer to the same hardware:

```shell
make compare COMPARE_SENSOR=hwmon/<chip>/<sensor>
make compare COMPARE_SENSOR=... COMPARE_WINDOW=2  # average two hours on each side
```

`COMPARE_WINDOW` sets the length of each window in whole hours and defaults to one hour. `COMPARE_AT` compares around a specified time instead of the latest annotation.

`COMPARE_SETTLE` delays the after window so a temperature that is still falling is not treated as settled. It defaults to half an hour. Because it is a timestamp offset rather than a window length, it may be fractional.

Before changing anything, compare two untouched windows to establish the normal drift between them. A measured change should exceed that drift to be considered meaningful.

## Setup

The stack and Jsonnet build/lint tooling run in containers; the runtime defaults to `docker`. Set `CONTAINER_RUNTIME=podman` on each Make invocation to use Podman instead. The Makefile assumes a GNU/Linux-style userland; the notable workstation dependencies are `make`, `curl`, `jq`, `ssh`, and `scp`.

### 1. Start the workstation stack

```shell
make up
```

**Prometheus** http://localhost:9090 | **Grafana** http://localhost:3000 (admin/admin)

This stack keeps 7 days of metrics by default. `PROMETHEUS_RETENTION` takes any Prometheus duration:

```shell
make up PROMETHEUS_RETENTION=90d
```

The node installation commands below assume a Debian-family amd64 system with systemd.

### 2. Install Node Exporter on each node

```shell
NODE=<node-address>

ssh root@$NODE "apt-get update && apt-get install -y prometheus-node-exporter"

ssh root@$NODE "mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d"
scp config/node/node-exporter-listen.conf \
    root@$NODE:/etc/systemd/system/prometheus-node-exporter.service.d/listen.conf

ssh root@$NODE "systemctl daemon-reload && systemctl restart prometheus-node-exporter"
```

Confirm that temperature sensors are present. If the scrape succeeds, a count of `0` means Node Exporter is not exposing any hwmon temperature metrics on this hardware:

```shell
ssh root@$NODE "curl -fsS localhost:9100/metrics | grep -c node_hwmon_temp_celsius"
```

### 3. Install the OTel Collector on each node

Use the **contrib** distribution: the supplied config depends on components outside the core build (at the time of writing).

```shell
COLLECTOR=<workstation-address>
VERSION=0.160.0
DEB=otelcol-contrib_${VERSION}_linux_amd64.deb
URL=https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$VERSION

ssh root@$NODE "cd /tmp && curl -fsSL -O $URL/$DEB -O $URL/$DEB.sha256 && \
    echo \"\$(cat $DEB.sha256)  $DEB\" | sha256sum -c - && \
    dpkg -i $DEB && rm $DEB $DEB.sha256"

scp config/node/otel-collector.yaml root@$NODE:/etc/otelcol-contrib/config.yaml

# The config reads COLLECTOR_ENDPOINT from the environment.
ssh root@$NODE "mkdir -p /etc/systemd/system/otelcol-contrib.service.d"
scp config/node/otelcol-endpoint.conf root@$NODE:/etc/systemd/system/otelcol-contrib.service.d/endpoint.conf
ssh root@$NODE "echo COLLECTOR_ENDPOINT=$COLLECTOR:4317 > /etc/otelcol-contrib/endpoint.env"

ssh root@$NODE "systemctl daemon-reload && systemctl restart otelcol-contrib"
```

Hostname is detected automatically, so the same config deploys unmodified to every node.

### 4. Enable the PVE metric server

This requires Proxmox VE 9. In the web UI:

**Datacenter** -> **Metric Server** -> **Add** -> **OpenTelemetry**

| Field    | Value                   |
| -------- | ----------------------- |
| Name     | anything, e.g. `otel`   |
| Server   | `<workstation-address>` |
| Port     | `4318`                  |
| Protocol | HTTP                    |
| Path     | `/v1/metrics`           |

Remaining defaults are fine. The collector does not serve TLS, so Protocol must be HTTP. The metric server is datacenter-wide, so configure it once regardless of node count.

### 5. Verify

Open http://localhost:9090 and try `system_`, `hw_temperature_`, and `proxmox_` in the query box. Host, temperature, and PVE metrics should autocomplete within a minute.

## Troubleshooting

Substitute `podman compose` for `docker compose` when using Podman.

```shell
docker compose logs otel-collector     # workstation
journalctl -u otelcol-contrib -n 50    # node
ss -lntp | grep 9100                   # Node Exporter listening?
nc -zv <workstation-address> 4317      # node can reach workstation?
```

If the node collector will not start, `COLLECTOR_ENDPOINT` is usually unset. In that case it exits with `requires a non-empty "endpoint"`. The value arrives by `EnvironmentFile`, so check `/etc/otelcol-contrib/endpoint.env` rather than `systemctl show`.

## Teardown

On the workstation, `make down` stops the stack but keeps the Prometheus and Grafana volumes. `make purge` takes those too, and the metrics with them.

```shell
make purge
```

On each node, use `apt-get purge` rather than `remove` so the configs under `/etc` are removed too. Purging still leaves a few things behind. The systemd drop-ins and endpoint env file were never part of a package. The queue directory was, but dpkg keeps any owned directory that is not empty, and the persisted queue inside it is not packaged. Remove them separately.

```shell
ssh root@$NODE "apt-get purge -y otelcol-contrib prometheus-node-exporter && \
    rm -rf /etc/systemd/system/otelcol-contrib.service.d \
    /etc/systemd/system/prometheus-node-exporter.service.d \
    /etc/otelcol-contrib /var/lib/otelcol-contrib && \
    systemctl daemon-reload"
```

The `otelcol-contrib` and `prometheus` system users survive purging as well. Remove them with `userdel` if they are no longer used by anything else.
