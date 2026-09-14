local g = import 'github.com/grafana/grafonnet/gen/grafonnet-v13.0.0/main.libsonnet';

{
  ds:: 'prometheus',

  // Lowest free row beneath a laid-out band.
  endY(panels):: std.foldl(
    function(acc, p) std.max(acc, p.gridPos.y + p.gridPos.h),
    panels,
    0
  ),

  q(expr, legend)::
    g.query.prometheus.new($.ds, expr)
    + g.query.prometheus.withLegendFormat(legend),

  stat(title, unit, targets)::
    g.panel.stat.new(title)
    + g.panel.stat.standardOptions.withUnit(unit)
    + g.panel.stat.queryOptions.withTargets(targets),

  ts(title, unit, targets)::
    g.panel.timeSeries.new(title)
    + g.panel.timeSeries.standardOptions.withUnit(unit)
    + g.panel.timeSeries.queryOptions.withTargets(targets),

  // Green below the first value, then yellow, then red.
  grades(warn, bad)::
    g.panel.stat.standardOptions.thresholds.withSteps([
      { color: 'green', value: null },
      { color: 'yellow', value: warn },
      { color: 'red', value: bad },
    ]),

  // For values with no good or bad, only a magnitude.
  plain(colour)::
    g.panel.stat.standardOptions.color.withMode('fixed')
    + g.panel.stat.standardOptions.color.withFixedColor(colour),

  // Inventory, not a trend.
  noTrend:: g.panel.stat.options.withGraphMode('none'),

  // Stacked areas read as a total at the top edge, with the split below it.
  stacked::
    g.panel.timeSeries.fieldConfig.defaults.custom.withStacking({ mode: 'normal' })
    + g.panel.timeSeries.fieldConfig.defaults.custom.withFillOpacity(30),

  // One series needs no key.
  noLegend:: g.panel.timeSeries.options.legend.withShowLegend(false),

  // Values matter more than names once there are more than a handful of series.
  // A right-hand column only earns its width at that point; below a few series
  // the same table costs a row of height instead.
  legendTable(calcs, placement='right')::
    g.panel.timeSeries.options.legend.withDisplayMode('table')
    + g.panel.timeSeries.options.legend.withPlacement(placement)
    + g.panel.timeSeries.options.legend.withCalcs(calcs),

  // Marks a change across every panel. hide is the toggle, not the
  // markers. matchAny false requires every tag listed but tolerates extras,
  // so a layer can select on a subset of what a mark carries.
  annotationsByTag(name, tags, color):: {
    datasource: { type: 'grafana', uid: '-- Grafana --' },
    enable: true,
    hide: true,
    iconColor: color,
    name: name,
    target: {
      type: 'tags',
      tags: tags,
      limit: 100,
      matchAny: false,
    },
  },

  // A single host picker, driven by whichever metric the dashboard is about.
  hostVariable(metric)::
    g.dashboard.variable.query.new('host')
    + g.dashboard.variable.query.generalOptions.withLabel('Host')
    + g.dashboard.variable.query.queryTypes.withLabelValues('host_name', metric)
    + g.dashboard.variable.query.withDatasource('prometheus', $.ds)
    + g.dashboard.variable.query.refresh.onTime(),
}
