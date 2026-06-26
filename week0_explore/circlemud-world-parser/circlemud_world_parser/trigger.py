"""
Triggers (DG Scripts) — tbaMUD's `world/trg/*.trg` files.

A trigger record looks like:

    #3098
    Hello Midgaard DG Test~          <- name (~-terminated)
    0 g 100                          <- attach_type, trigger-type bitvector, numeric arg
    ~                                <- arglist (here empty, ~-terminated)
    wait 1 sec                       ┐
    say Welcome to Midgaard, ...     ├ command body (the DG script)
    ~                                ┘ <- terminator

The script body is captured verbatim — we do not interpret the DG language. The
attach_type/trigger-type tables are lifted from tbaMUD's src/dg_scripts.h via
constants.py (see TRIGGER_TYPE_TABLE).
"""
from pydantic import BaseModel, Field

from .constants import TRIGGER_TYPE_TABLE, TriggerAttachType
from .models import Flag
from .utils import lookup_value_to_dict, parse_flags


class Trigger(BaseModel):
    """A tbaMUD DG Script trigger definition."""

    id: int = Field(..., description="Trigger VNUM")
    name: str = Field(..., description="Trigger name")
    attach_type: Flag = Field(..., description="What it attaches to (MOB/OBJ/WLD)")
    trigger_types: list[Flag] = Field(
        default_factory=list, description="Decoded trigger-type bitvector"
    )
    numeric_arg: int = Field(0, description="Percent chance / command subtype (per type)")
    arglist: str = Field("", description="Argument line (e.g. command keyword); may be empty")
    commands: str = Field("", description="Raw DG script body, newlines preserved")

    @classmethod
    def from_text(cls, text: str) -> "Trigger":
        """Parse a single trigger record from raw text."""
        lines = text.split('\n')
        trig_id = int(lines[0].lstrip('#'))

        # Everything after the vnum line splits on '~' into: name, then the
        # meta-line + arglist block, then the command body. Indexing positionally
        # tolerates the missing final '~' the file-level rstrip removes from the
        # last record in a file.
        rest = '\n'.join(lines[1:])
        parts = rest.split('~')

        name = parts[0].strip()

        meta_block = parts[1].lstrip('\n') if len(parts) > 1 else ''
        meta_lines = meta_block.split('\n')
        meta_tokens = meta_lines[0].split()
        attach_value = int(meta_tokens[0])
        bitvector = meta_tokens[1] if len(meta_tokens) > 1 else '0'
        numeric_arg = int(meta_tokens[2]) if len(meta_tokens) > 2 else 0
        arglist = '\n'.join(meta_lines[1:]).strip()

        commands = parts[2].strip('\n') if len(parts) > 2 else ''

        attach_type = TriggerAttachType(attach_value)
        attach_flag = Flag(**lookup_value_to_dict(attach_value, TriggerAttachType))
        trigger_types = parse_flags(bitvector, TRIGGER_TYPE_TABLE[attach_type])

        return cls(
            id=trig_id,
            name=name,
            attach_type=attach_flag,
            trigger_types=trigger_types,
            numeric_arg=numeric_arg,
            arglist=arglist,
            commands=commands,
        )
