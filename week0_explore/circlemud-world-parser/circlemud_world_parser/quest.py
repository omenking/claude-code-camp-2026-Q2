"""
Quests — tbaMUD's `world/qst/*.qst` files.

A quest record (field order lifted from parse_quest in tbaMUD's src/quest.c):

    #100
    Kill the Mice!~                     <- name
    mice~                               <- desc (keyword list; shown as "offer")
    I really need some help ...~        <- info
    Well done! ...~                     <- done (completion)
    You have abandoned the quest.~      <- quit (abandon)
    3 179 0 194 -1 -1 -1                <- type qm flags target prev_quest next_quest prereq
    0 0 1 34 60 -1 3                    <- value[0..6]
    10 0 65535                          <- gold_reward exp_reward obj_reward
    S                                   <- record terminator

Five ~-terminated strings, then three numeric lines. 65535 (NOTHING/NOBODY) is
normalised to -1 so "none" is uniform with the rest of the world data.
"""
from pydantic import BaseModel, Field

from .constants import QuestFlag, QuestType
from .models import Flag
from .utils import lookup_value_to_dict, parse_flags

# tbaMUD sentinel for "no object / no mob / nowhere".
NONE_SENTINEL = 65535


def _none(value: int) -> int:
    """Map tbaMUD's 65535 sentinel to the -1 "none" convention."""
    return -1 if value == NONE_SENTINEL else value


class QuestMessages(BaseModel):
    """The four ~-terminated message strings shown at each quest stage."""

    offer: str = Field("", description="Offer / keyword description")
    info: str = Field("", description="Info text shown when the quest is taken")
    done: str = Field("", description="Completion text")
    quit: str = Field("", description="Abandon text")


class QuestRewards(BaseModel):
    """Rewards granted on completion."""

    gold: int = Field(0, description="Gold reward")
    exp: int = Field(0, description="Experience reward")
    obj: int = Field(-1, description="Object VNUM reward (-1 = none)")


class Quest(BaseModel):
    """A tbaMUD quest definition."""

    id: int = Field(..., description="Quest VNUM")
    name: str = Field(..., description="Quest title")
    messages: QuestMessages = Field(..., description="Stage message strings")
    questmaster: int = Field(-1, description="Mob VNUM that assigns the quest (-1 = none)")
    type: Flag = Field(..., description="Objective type (AQ_*)")
    flags: list[Flag] = Field(default_factory=list, description="Quest flags")
    target: int = Field(-1, description="Objective target VNUM, interpreted per type")
    prev_quest: int = Field(-1, description="Previous quest in chain (-1 = none)")
    next_quest: int = Field(-1, description="Next quest in chain (-1 = none)")
    prereq: int = Field(-1, description="Prerequisite object the player must hold (-1 = none)")
    value: list[int] = Field(default_factory=list, description="Raw value[0..6] slots")
    rewards: QuestRewards = Field(..., description="Completion rewards")

    @classmethod
    def from_text(cls, text: str) -> "Quest":
        """Parse a single quest record from raw text."""
        lines = text.split('\n')
        quest_id = int(lines[0].lstrip('#'))

        # Five ~-terminated strings, then the numeric block. Splitting on '~'
        # positionally tolerates the file-level rstrip on the last record.
        rest = '\n'.join(lines[1:])
        parts = rest.split('~')

        name = parts[0].strip()
        messages = QuestMessages(
            offer=parts[1].strip('\n') if len(parts) > 1 else '',
            info=parts[2].strip('\n') if len(parts) > 2 else '',
            done=parts[3].strip('\n') if len(parts) > 3 else '',
            quit=parts[4].strip('\n') if len(parts) > 4 else '',
        )

        num_lines = [line for line in parts[5].split('\n') if line.strip()] if len(parts) > 5 else []
        line1 = [int(t) for t in num_lines[0].split()]
        line2 = [int(t) for t in num_lines[1].split()] if len(num_lines) > 1 else []
        line3 = [int(t) for t in num_lines[2].split()] if len(num_lines) > 2 else []

        quest_type = Flag(**lookup_value_to_dict(line1[0], QuestType))
        questmaster = _none(line1[1])
        flags = parse_flags(str(line1[2]), QuestFlag)
        target = _none(line1[3])
        prev_quest = line1[4]
        next_quest = line1[5]
        prereq = _none(line1[6])

        rewards = QuestRewards(
            gold=line3[0] if len(line3) > 0 else 0,
            exp=line3[1] if len(line3) > 1 else 0,
            obj=_none(line3[2]) if len(line3) > 2 else -1,
        )

        return cls(
            id=quest_id,
            name=name,
            messages=messages,
            questmaster=questmaster,
            type=quest_type,
            flags=flags,
            target=target,
            prev_quest=prev_quest,
            next_quest=next_quest,
            prereq=prereq,
            value=line2,
            rewards=rewards,
        )
