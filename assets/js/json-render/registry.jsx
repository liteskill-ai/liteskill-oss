import React from "react"
import { defineRegistry } from "@json-render/react"
import { catalog } from "./catalog"

const CHART_COLORS = [
  "#6366f1", "#f59e0b", "#10b981", "#ef4444", "#3b82f6",
  "#8b5cf6", "#ec4899", "#14b8a6", "#f97316", "#06b6d4",
]

const GAP = { sm: "gap-2", md: "gap-4", lg: "gap-6" }
const PAD = { sm: "p-2", md: "p-4", lg: "p-6" }

export const { registry } = defineRegistry(catalog, {
  components: {
    Card: ({ props, children }) => (
      <div className={`rounded-xl border border-base-300 bg-base-100 shadow-sm ${PAD[props.padding] || "p-4"}`}>
        <h3 className="text-lg font-semibold text-base-content">{props.title}</h3>
        {props.description && (
          <p className="mt-1 text-sm text-base-content/60">{props.description}</p>
        )}
        <div className="mt-3">{children}</div>
      </div>
    ),

    Metric: ({ props }) => {
      const trendIcon = props.trend === "up" ? "↑" : props.trend === "down" ? "↓" : props.trend === "flat" ? "→" : null
      const trendColor = props.trend === "up" ? "text-success" : props.trend === "down" ? "text-error" : "text-base-content/50"
      return (
        <div className="flex flex-col">
          <span className="text-xs font-medium text-base-content/60 uppercase tracking-wide">{props.label}</span>
          <div className="flex items-baseline gap-2">
            <span className="text-2xl font-bold text-base-content">{props.value}</span>
            {trendIcon && <span className={`text-sm font-medium ${trendColor}`}>{trendIcon}</span>}
          </div>
        </div>
      )
    },

    Table: ({ props }) => (
      <div className="overflow-x-auto">
        {props.caption && <p className="mb-2 text-sm text-base-content/60">{props.caption}</p>}
        <table className="table table-sm w-full">
          <thead>
            <tr>
              {(props.headers || []).map((h, i) => (
                <th key={i} className="text-xs font-semibold uppercase tracking-wide text-base-content/70">{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {(props.rows || []).map((row, ri) => (
              <tr key={ri} className="hover:bg-base-200/50">
                {row.map((cell, ci) => (
                  <td key={ci} className="text-sm">{cell}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    ),

    BarChart: ({ props }) => {
      const vals = props.values || []
      const labels = props.labels || []
      const maxVal = Math.max(...vals, 1)
      const color = props.color || CHART_COLORS[0]
      const isHorizontal = props.direction === "horizontal"

      if (isHorizontal) {
        return (
          <div className="space-y-2">
            {props.title && <p className="text-sm font-semibold text-base-content">{props.title}</p>}
            {labels.map((label, i) => (
              <div key={i} className="flex items-center gap-2">
                <span className="text-xs text-base-content/60 w-20 truncate text-right">{label}</span>
                <div className="flex-1 bg-base-200 rounded-full h-5 overflow-hidden">
                  <div
                    className="h-full rounded-full transition-all duration-500"
                    style={{ width: `${(vals[i] / maxVal) * 100}%`, backgroundColor: CHART_COLORS[i % CHART_COLORS.length] }}
                  />
                </div>
                <span className="text-xs text-base-content/70 w-12">{vals[i]}</span>
              </div>
            ))}
          </div>
        )
      }

      return (
        <div className="space-y-2">
          {props.title && <p className="text-sm font-semibold text-base-content">{props.title}</p>}
          <div className="flex items-end gap-1 h-40">
            {labels.map((label, i) => (
              <div key={i} className="flex-1 flex flex-col items-center justify-end h-full">
                <span className="text-[10px] text-base-content/70 mb-1">{vals[i]}</span>
                <div
                  className="w-full rounded-t transition-all duration-500"
                  style={{ height: `${(vals[i] / maxVal) * 100}%`, backgroundColor: CHART_COLORS[i % CHART_COLORS.length] }}
                />
                <span className="text-[10px] text-base-content/60 mt-1 truncate w-full text-center">{label}</span>
              </div>
            ))}
          </div>
        </div>
      )
    },

    LineChart: ({ props }) => {
      const vals = props.values || []
      const labels = props.labels || []
      const maxVal = Math.max(...vals, 1)
      const minVal = Math.min(...vals, 0)
      const range = maxVal - minVal || 1
      const color = props.color || CHART_COLORS[0]
      const h = 120
      const w = 300
      const points = vals.map((v, i) => {
        const x = vals.length > 1 ? (i / (vals.length - 1)) * w : w / 2
        const y = h - ((v - minVal) / range) * h
        return `${x},${y}`
      })

      return (
        <div className="space-y-2">
          {props.title && <p className="text-sm font-semibold text-base-content">{props.title}</p>}
          <svg viewBox={`0 0 ${w} ${h + 20}`} className="w-full" preserveAspectRatio="xMidYMid meet">
            <polyline
              fill="none"
              stroke={color}
              strokeWidth="2"
              strokeLinejoin="round"
              strokeLinecap="round"
              points={points.join(" ")}
            />
            {vals.map((v, i) => {
              const x = vals.length > 1 ? (i / (vals.length - 1)) * w : w / 2
              const y = h - ((v - minVal) / range) * h
              return <circle key={i} cx={x} cy={y} r="3" fill={color} />
            })}
            {labels.map((label, i) => {
              const x = vals.length > 1 ? (i / (vals.length - 1)) * w : w / 2
              return (
                <text key={i} x={x} y={h + 14} textAnchor="middle" className="fill-base-content/50" style={{ fontSize: "8px" }}>
                  {label}
                </text>
              )
            })}
          </svg>
        </div>
      )
    },

    PieChart: ({ props }) => {
      const vals = props.values || []
      const labels = props.labels || []
      const total = vals.reduce((a, b) => a + b, 0) || 1
      const r = 50
      const cx = 60
      const cy = 60
      let cumAngle = -Math.PI / 2

      const slices = vals.map((v, i) => {
        const angle = (v / total) * 2 * Math.PI
        const x1 = cx + r * Math.cos(cumAngle)
        const y1 = cy + r * Math.sin(cumAngle)
        cumAngle += angle
        const x2 = cx + r * Math.cos(cumAngle)
        const y2 = cy + r * Math.sin(cumAngle)
        const largeArc = angle > Math.PI ? 1 : 0
        const d = `M ${cx} ${cy} L ${x1} ${y1} A ${r} ${r} 0 ${largeArc} 1 ${x2} ${y2} Z`
        return <path key={i} d={d} fill={CHART_COLORS[i % CHART_COLORS.length]} />
      })

      return (
        <div className="space-y-2">
          {props.title && <p className="text-sm font-semibold text-base-content">{props.title}</p>}
          <div className="flex items-start gap-4">
            <svg viewBox="0 0 120 120" className="w-28 h-28 flex-shrink-0">{slices}</svg>
            <div className="flex flex-col gap-1 text-xs">
              {labels.map((label, i) => (
                <div key={i} className="flex items-center gap-1.5">
                  <span className="w-2.5 h-2.5 rounded-sm flex-shrink-0" style={{ backgroundColor: CHART_COLORS[i % CHART_COLORS.length] }} />
                  <span className="text-base-content/70">{label}</span>
                  <span className="text-base-content/50 ml-auto">{Math.round((vals[i] / total) * 100)}%</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )
    },

    List: ({ props }) => (
      <div>
        {props.title && <p className="text-sm font-semibold text-base-content mb-2">{props.title}</p>}
        {props.ordered ? (
          <ol className="list-decimal list-inside space-y-1 text-sm text-base-content">
            {(props.items || []).map((item, i) => <li key={i}>{item}</li>)}
          </ol>
        ) : (
          <ul className="list-disc list-inside space-y-1 text-sm text-base-content">
            {(props.items || []).map((item, i) => <li key={i}>{item}</li>)}
          </ul>
        )}
      </div>
    ),

    Alert: ({ props }) => {
      const styles = {
        info:    "bg-info/10 border-info/30 text-info",
        success: "bg-success/10 border-success/30 text-success",
        warning: "bg-warning/10 border-warning/30 text-warning",
        error:   "bg-error/10 border-error/30 text-error",
      }
      const icons = { info: "ℹ", success: "✓", warning: "⚠", error: "✕" }
      const s = styles[props.severity] || styles.info
      return (
        <div className={`rounded-lg border p-3 ${s}`}>
          <div className="flex gap-2">
            <span className="text-lg leading-none">{icons[props.severity] || icons.info}</span>
            <div className="flex-1">
              {props.title && <p className="font-semibold text-sm">{props.title}</p>}
              <p className="text-sm opacity-90">{props.message}</p>
            </div>
          </div>
        </div>
      )
    },

    Progress: ({ props }) => {
      const pct = Math.max(0, Math.min(100, props.value || 0))
      const color = props.color || "#6366f1"
      return (
        <div className="space-y-1">
          <div className="flex justify-between text-xs text-base-content/70">
            <span>{props.label}</span>
            <span>{pct}%</span>
          </div>
          <div className="w-full bg-base-200 rounded-full h-2.5 overflow-hidden">
            <div
              className="h-full rounded-full transition-all duration-500"
              style={{ width: `${pct}%`, backgroundColor: color }}
            />
          </div>
        </div>
      )
    },

    Badge: ({ props }) => {
      const styles = {
        default: "badge",
        primary: "badge badge-primary",
        success: "badge badge-success",
        warning: "badge badge-warning",
        error:   "badge badge-error",
      }
      return <span className={`${styles[props.variant] || styles.default} badge-sm`}>{props.text}</span>
    },

    Stack: ({ props, children }) => {
      const dir = props.direction === "horizontal" ? "flex-row" : "flex-col"
      const gap = GAP[props.gap] || GAP.md
      const alignMap = { start: "items-start", center: "items-center", end: "items-end", stretch: "items-stretch" }
      const align = alignMap[props.align] || ""
      return <div className={`flex ${dir} ${gap} ${align}`}>{children}</div>
    },

    Grid: ({ props, children }) => {
      const cols = { 1: "grid-cols-1", 2: "grid-cols-2", 3: "grid-cols-3", 4: "grid-cols-4", 5: "grid-cols-5", 6: "grid-cols-6" }
      const gap = GAP[props.gap] || GAP.md
      return <div className={`grid ${cols[props.columns] || "grid-cols-2"} ${gap}`}>{children}</div>
    },

    Button: ({ props }) => {
      const styles = {
        primary:   "btn btn-primary btn-sm",
        secondary: "btn btn-secondary btn-sm",
        ghost:     "btn btn-ghost btn-sm",
      }
      return (
        <button
          className={styles[props.variant] || styles.primary}
          disabled={!!props.disabled}
        >
          {props.label}
        </button>
      )
    },
  },
})
