import { useState } from "react";
import type { DroppedEvent } from "../api/types";
import { fmtBytes } from "../format";
import Ansi from "./Ansi";

const CAUSE_LABEL: Record<DroppedEvent["cause"], string> = {
  pre_command_drain: "pre-command drain",
  post_prompt_leftover: "prompt leftover",
  login: "login dance",
};

// The headline feature from spec §5.1: a muted bar marking bytes the MUD
// sent that never reached any tool call (§0.2's drain loss, made visible via
// Diff::TelnetManager, §3.6). Collapsed by default — expanding shows the
// ANSI-rendered text the agent never saw.
export default function DroppedStrip({ event }: { event: DroppedEvent }) {
  const [open, setOpen] = useState(false);
  const eventCount = event.telnet_seqs.length;

  return (
    <div className="dropped-strip">
      <button type="button" className="dropped-strip-toggle" onClick={() => setOpen((o) => !o)}>
        <span className={open ? "dropped-strip-caret open" : "dropped-strip-caret"}>▾</span>
        {eventCount} event{eventCount === 1 ? "" : "s"} dropped · {fmtBytes(event.bytes)} ·{" "}
        {CAUSE_LABEL[event.cause]}
      </button>
      {open && (
        <pre className="dropped-strip-body">
          <Ansi html={event.text_html} />
        </pre>
      )}
    </div>
  );
}
