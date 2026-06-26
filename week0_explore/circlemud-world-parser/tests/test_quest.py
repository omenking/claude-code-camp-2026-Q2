import pytest

from circlemud_world_parser.quest import Quest


class TestQuestParsing:
    @pytest.fixture
    def quest_text(self):
        # Stock quest #100 "Kill the Mice!" from 1.qst.
        return (
            "100\n"
            "Kill the Mice!~\n"
            "mice~\n"
            "   I really need some help killing these mice or the Sarge is going to make my\n"
            "life a living hell.\n"
            "~\n"
            "   Well done!  You have completed your quest!\n"
            "~\n"
            "You have abandoned the quest.\n"
            "~\n"
            "3 179 0 194 -1 -1 -1\n"
            "0 0 1 34 60 -1 3\n"
            "10 0 65535\n"
            "S\n"
        )

    def test_parsing_quest(self, quest_text):
        quest = Quest.from_text(quest_text)

        assert quest.id == 100
        assert quest.name == "Kill the Mice!"

        # offer is the desc/keyword line; info preserves its internal newline + indent.
        assert quest.messages.offer == "mice"
        assert quest.messages.info.startswith("   I really need some help")
        assert "life a living hell." in quest.messages.info
        assert quest.messages.done == "   Well done!  You have completed your quest!"
        assert quest.messages.quit == "You have abandoned the quest."

        # First numeric line: type qm flags target prev next prereq
        assert quest.type.value == 3
        assert quest.type.note == "MOB_KILL"
        assert quest.questmaster == 179
        assert quest.flags == []  # flags field was 0
        assert quest.target == 194
        assert quest.prev_quest == -1
        assert quest.next_quest == -1
        assert quest.prereq == -1

        # Second numeric line: raw value[0..6]
        assert quest.value == [0, 0, 1, 34, 60, -1, 3]

        # Third numeric line: gold exp obj — 65535 normalises to -1 (no obj reward).
        assert quest.rewards.gold == 10
        assert quest.rewards.exp == 0
        assert quest.rewards.obj == -1

    def test_repeatable_flag_decodes(self, quest_text):
        text = quest_text.replace("3 179 0 194 -1 -1 -1", "3 179 1 194 -1 -1 -1")
        quest = Quest.from_text(text)
        assert len(quest.flags) == 1
        assert quest.flags[0].note == "REPEATABLE"

    def test_vnum_prefix_hash_tolerated(self, quest_text):
        quest = Quest.from_text("#" + quest_text)
        assert quest.id == 100
