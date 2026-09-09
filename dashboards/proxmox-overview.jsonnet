local g = import 'github.com/grafana/grafonnet/gen/grafonnet-v13.0.0/main.libsonnet';
local lib = import 'lib.libsonnet';

local uptime =
  lib.stat('Uptime', 's', [lib.q('max(proxmox_node_uptime_seconds{host_name="$host"})', 'uptime')])
  + lib.plain('blue');

local nodeCpu =
  lib.stat('Node CPU', 'percentunit', [lib.q('max(proxmox_node_cpustat_cpu_percent{host_name="$host"})', 'cpu')])
  + lib.grades(0.7, 0.9);

local nodeMemory =
  lib.stat('Node memory', 'percentunit', [
    lib.q('max(proxmox_node_memory_memused_bytes{host_name="$host"} / proxmox_node_memory_memtotal_bytes{host_name="$host"})', 'used'),
  ])
  + lib.grades(0.8, 0.95);

local arc =
  lib.stat('ZFS ARC', 'bytes', [lib.q('max(proxmox_node_memory_arcsize_bytes{host_name="$host"})', 'arc')])
  + lib.plain('purple');

local guestsRunning =
  lib.stat('Guests running', 'short', [
    lib.q('count(count by (vmid) (proxmox_vm_uptime_seconds{host_name="$host"} > 0))', 'running'),
  ])
  + lib.plain('text')
  + lib.noTrend;

local guestsTotal =
  lib.stat('Guests defined', 'short', [
    lib.q('count(count by (vmid) (proxmox_vm_uptime_seconds{host_name="$host"}))', 'defined'),
  ])
  + lib.plain('text')
  + lib.noTrend;

local guestCpu =
  lib.ts('CPU by guest', 'percentunit', [lib.q('sum by (name) (proxmox_vm_cpu_percent{host_name="$host"})', '{{name}}')])
  + lib.stacked
  + lib.legendTable(['lastNotNull', 'max']);

local guestMemory =
  lib.ts('Memory by guest', 'bytes', [lib.q('sum by (name) (proxmox_vm_mem_bytes{host_name="$host"})', '{{name}}')])
  + lib.stacked
  + lib.legendTable(['lastNotNull', 'max']);

// Allocation is a ceiling the guest can hit; usage alone does not show headroom.
local guestMemoryShare =
  lib.ts('Memory vs allocated', 'percentunit', [
    lib.q('max by (name) (proxmox_vm_mem_bytes{host_name="$host"} / proxmox_vm_maxmem_bytes{host_name="$host"})', '{{name}}'),
  ])
  + lib.legendTable(['lastNotNull', 'max']);

local guestDisk =
  lib.ts('Disk I/O by guest', 'Bps', [
    lib.q('sum by (name) (rate(proxmox_vm_diskread_bytes_total{host_name="$host"}[$__rate_interval]))', '{{name}} read'),
    lib.q('sum by (name) (rate(proxmox_vm_diskwrite_bytes_total{host_name="$host"}[$__rate_interval]))', '{{name}} write'),
  ])
  + lib.legendTable(['lastNotNull', 'max']);

local guestNetwork =
  lib.ts('Network by guest', 'Bps', [
    lib.q('sum by (name) (rate(proxmox_vm_netin_bytes_total{host_name="$host"}[$__rate_interval]))', '{{name}} in'),
    lib.q('sum by (name) (rate(proxmox_vm_netout_bytes_total{host_name="$host"}[$__rate_interval]))', '{{name}} out'),
  ])
  + lib.legendTable(['lastNotNull', 'max']);

local storageUsed =
  lib.ts('Storage used', 'percentunit', [
    lib.q('max by (storage) (proxmox_storage_used_bytes{host_name="$host"} / proxmox_storage_total_bytes{host_name="$host"})', '{{storage}}'),
  ])
  + lib.legendTable(['lastNotNull'], placement='bottom');

local nodeNetwork =
  lib.ts('Node network', 'Bps', [
    lib.q('sum by (device) (rate(proxmox_node_network_receive_bytes_total{host_name="$host", device!~"(tap|veth|fwbr|fwln|fwpr).*|lo"}[$__rate_interval]))', '{{device}} in'),
    lib.q('sum by (device) (rate(proxmox_node_network_transmit_bytes_total{host_name="$host", device!~"(tap|veth|fwbr|fwln|fwpr).*|lo"}[$__rate_interval]))', '{{device}} out'),
  ])
  + lib.legendTable(['lastNotNull', 'max']);

// PVE labels these _ratio, but they are raw load averages.
local nodeLoad =
  lib.ts('Node load average', 'short', [
    lib.q('max(proxmox_node_cpustat_avg1_ratio{host_name="$host"})', '1m'),
    lib.q('max(proxmox_node_cpustat_avg5_ratio{host_name="$host"})', '5m'),
    lib.q('max(proxmox_node_cpustat_avg15_ratio{host_name="$host"})', '15m'),
  ]);

g.dashboard.new('Proxmox Overview')
+ g.dashboard.withUid('proxmox-overview')
+ g.dashboard.withDescription('Cluster, guest and storage state from the PVE metric server.')
+ g.dashboard.withEditable(false)
+ g.dashboard.withTimezone('browser')
+ g.dashboard.withRefresh('30s')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.withVariables([lib.hostVariable('proxmox_node_uptime_seconds')])
+ g.dashboard.withPanels(
  local overview = g.util.grid.makeGrid([
    g.panel.row.new('Node')
    + g.panel.row.withPanels([uptime, nodeCpu, nodeMemory, arc, guestsRunning, guestsTotal]),
  ], panelWidth=4, panelHeight=4);

  local detail = g.util.grid.makeGrid([
    g.panel.row.new('Guests')
    + g.panel.row.withPanels([guestCpu, guestMemory, guestMemoryShare]),

    g.panel.row.new('Guest I/O')
    + g.panel.row.withPanels([guestDisk, guestNetwork]),

    g.panel.row.new('Node and storage')
    + g.panel.row.withPanels([nodeNetwork, nodeLoad, storageUsed]),
  ], panelWidth=8, panelHeight=8, startY=lib.endY(overview));

  overview + detail
)
