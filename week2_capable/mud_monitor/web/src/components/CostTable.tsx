import type { CostBreakdownRow } from "../api/types";
import { fmtCostCell, fmtTokens } from "../format";

// Port of log_viz session.erb's cost-by-task-and-model table.
export default function CostTable({ rows }: { rows: CostBreakdownRow[] }) {
  if (rows.length === 0) return null;

  return (
    <div className="breakdown">
      <div className="breakdown-title">Cost by task / provider / model</div>
      <table className="breakdown-table">
        <thead>
          <tr>
            <th>Task</th>
            <th>Provider</th>
            <th>Model</th>
            <th className="nowrap">Calls</th>
            <th className="nowrap">Tokens</th>
            <th className="nowrap">Cost</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={`${row.task}-${row.provider}-${row.model}`}>
              <td>{row.task}</td>
              <td>{row.provider}</td>
              <td>{row.model}</td>
              <td className="nowrap">{row.calls}</td>
              <td className="nowrap">
                {fmtTokens(row.input)} / {fmtTokens(row.output)}
              </td>
              <td className="nowrap">{fmtCostCell(row.cost, row.cost_known)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
