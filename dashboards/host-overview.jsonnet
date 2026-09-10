local g = import 'github.com/grafana/grafonnet/gen/grafonnet-v13.0.0/main.libsonnet';
local lib = import 'lib.libsonnet';

local uptime =
  lib.stat('Uptime', 's', [lib.q('max by (host_name) (system_uptime_seconds{host_name="$host"})', '{{host_name}}')])
  + lib.plain('blue');

local load =
  lib.stat('Load per CPU', 'percentunit', [
    lib.q('max(system_cpu_load_average_1m{host_name="$host"} / on(host_name) group_left system_cpu_logical_count{host_name="$host"})', '1m'),
  ])
  + lib.grades(0.7, 1.0);

local hottest =
  lib.stat('Hottest sensor', 'celsius', [lib.q('max(hw_temperature_celsius{host_name="$host"})', 'max')])
  + lib.grades(65, 80);

local power =
  lib.stat('Package power', 'watt', [lib.q('max by (hw_id) (hw_power_watts{host_name="$host"})', '{{hw_id}}')])
  + lib.plain('purple');

local cpuBusy =
  lib.stat('CPU busy', 'percentunit', [
    lib.q('1 - (sum(rate(system_cpu_time_seconds_total{host_name="$host", state="idle"}[$__rate_interval])) / scalar(system_cpu_logical_count{host_name="$host"}))', 'busy'),
  ])
  + lib.grades(0.7, 0.9);

local memoryUsed =
  lib.stat('Memory used', 'percentunit', [
    lib.q('sum(system_memory_usage_bytes{host_name="$host", state="used"}) / scalar(system_memory_limit_bytes{host_name="$host"})', 'used'),
  ])
  + lib.grades(0.8, 0.95);

local totalMemory =
  lib.stat('Total memory', 'bytes', [lib.q('system_memory_limit_bytes{host_name="$host"}', 'total')])
  + lib.plain('text')
  + lib.noTrend;

local cpus =
  lib.stat('CPUs', 'short', [lib.q('max(system_cpu_logical_count{host_name="$host"})', 'logical')])
  + lib.plain('text')
  + lib.noTrend;

local cpuTime =
  lib.ts('CPU time by state', 'percentunit', [
    lib.q('sum by (state) (rate(system_cpu_time_seconds_total{host_name="$host", state!="idle"}[$__rate_interval])) / scalar(system_cpu_logical_count{host_name="$host"})', '{{state}}'),
  ])
  + lib.stacked;

local memory =
  lib.ts('Memory by state', 'bytes', [
    lib.q('sum by (state) (system_memory_usage_bytes{host_name="$host", state!~"slab.*"})', '{{state}}'),
  ])
  + lib.stacked;

local loadAverage =
  lib.ts('Load average', 'short', [
    lib.q('max(system_cpu_load_average_1m{host_name="$host"})', '1m'),
    lib.q('max(system_cpu_load_average_5m{host_name="$host"})', '5m'),
    lib.q('max(system_cpu_load_average_15m{host_name="$host"})', '15m'),
  ]);

local temperature =
  lib.ts('Temperature by sensor', 'celsius', [
    lib.q('max by (hw_id) (hw_temperature_celsius{host_name="$host"})', '{{hw_id}}'),
  ])
  + lib.legendTable(['mean', 'max', 'lastNotNull']);

local powerDraw =
  lib.ts('Power by sensor', 'watt', [
    lib.q('max by (hw_id) (hw_power_watts{host_name="$host"})', '{{hw_id}}'),
  ])
  + lib.legendTable(['mean', 'max', 'lastNotNull'], placement='bottom');

local cpuFrequency =
  lib.ts('CPU frequency', 'hertz', [
    lib.q('avg(node_cpu_scaling_frequency_hertz{host_name="$host"})', 'avg'),
    lib.q('max(node_cpu_scaling_frequency_hertz{host_name="$host"})', 'max'),
  ])
  + lib.legendTable(['mean', 'min', 'max'], placement='bottom');

local diskIO =
  lib.ts('Disk I/O', 'Bps', [
    lib.q('sum by (device, direction) (rate(system_disk_io_bytes_total{host_name="$host", device!~".+p[0-9]+"}[$__rate_interval]))', '{{device}} {{direction}}'),
  ]);

local filesystem =
  lib.ts('Filesystem used', 'bytes', [
    lib.q('sum by (mountpoint) (system_filesystem_usage_bytes{host_name="$host", state="used"})', '{{mountpoint}}'),
  ]);

local networkIO =
  lib.ts('Network I/O', 'Bps', [
    lib.q('sum by (device, direction) (rate(system_network_io_bytes_total{host_name="$host", device!~"(tap|veth|fwbr|fwln|fwpr).*|lo"}[$__rate_interval]))', '{{device}} {{direction}}'),
  ]);

g.dashboard.new('Host Overview')
+ g.dashboard.withUid('host-overview')
+ g.dashboard.withDescription('OS-level metrics from the node collectors, plus hwmon sensors.')
+ g.dashboard.withEditable(false)
+ g.dashboard.withTimezone('browser')
+ g.dashboard.withRefresh('30s')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.withVariables([lib.hostVariable('system_uptime_seconds')])
+ g.dashboard.withAnnotations([
  lib.annotationsByTag('Door', 'door', 'blue'),
  lib.annotationsByTag('Fan', 'fan', 'orange'),
])
+ g.dashboard.withPanels(
  local overview = g.util.grid.makeGrid([
    g.panel.row.new('Overview')
    + g.panel.row.withPanels([uptime, cpuBusy, memoryUsed, load, hottest, power, totalMemory, cpus]),
  ], panelWidth=3, panelHeight=4);

  local detail = g.util.grid.makeGrid([
    g.panel.row.new('Compute')
    + g.panel.row.withPanels([cpuTime, memory, loadAverage]),

    g.panel.row.new('Thermal')
    + g.panel.row.withPanels([temperature, powerDraw, cpuFrequency]),

    g.panel.row.new('Storage and network')
    + g.panel.row.withPanels([diskIO, filesystem, networkIO]),
  ], panelWidth=8, panelHeight=8, startY=lib.endY(overview));

  overview + detail
)
