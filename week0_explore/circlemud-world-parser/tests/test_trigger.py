import pytest

from circlemud_world_parser.trigger import Trigger


class TestTriggerParsing:
    @pytest.fixture
    def greet_trigger(self):
        # The proof-of-life trigger #3098 (mob greet).
        return (
            "3098\n"
            "Hello Midgaard DG Test~\n"
            "0 g 100\n"
            "~\n"
            "wait 1 sec\n"
            "say Welcome to Midgaard, %actor.name%! The DG engine lives.\n"
            "~\n"
        )

    @pytest.fixture
    def command_trigger(self):
        # Object command trigger #10302 with a non-empty arglist.
        return (
            "10302\n"
            "Room Command - Teleporter to Earth - 10302~\n"
            "1 c 100\n"
            "enter~\n"
            "if %cmd.mudcommand% == enter && teleporter /= %arg% && %arg%\n"
            "  %teleport% %actor% 3001\n"
            "end\n"
            "~\n"
        )

    @pytest.fixture
    def room_trigger(self):
        # World/room trigger #3004 (the Dump): drops in room.
        return (
            "3004\n"
            "Dump - 3030~\n"
            "2 h 100\n"
            "~\n"
            "* dump room script\n"
            "~\n"
        )

    def test_mob_greet_trigger(self, greet_trigger):
        trig = Trigger.from_text(greet_trigger)

        assert trig.id == 3098
        assert trig.name == "Hello Midgaard DG Test"
        assert trig.attach_type.value == 0
        assert trig.attach_type.note == "MOB"
        # 'g' is letter-bit 6 -> MTRIG_GREET (1 << 6 == 64)
        assert len(trig.trigger_types) == 1
        assert trig.trigger_types[0].value == 64
        assert trig.trigger_types[0].note == "GREET"
        assert trig.numeric_arg == 100
        assert trig.arglist == ""
        assert "wait 1 sec" in trig.commands
        assert "The DG engine lives." in trig.commands
        # Script body preserves newlines and excludes the terminator.
        assert "~" not in trig.commands
        assert trig.commands.count("\n") == 1

    def test_object_command_trigger(self, command_trigger):
        trig = Trigger.from_text(command_trigger)

        assert trig.id == 10302
        assert trig.attach_type.note == "OBJ"
        # 'c' is letter-bit 2 -> OTRIG_COMMAND (1 << 2 == 4)
        assert trig.trigger_types[0].value == 4
        assert trig.trigger_types[0].note == "COMMAND"
        assert trig.numeric_arg == 100
        assert trig.arglist == "enter"
        assert trig.commands.startswith("if %cmd.mudcommand%")

    def test_room_drop_trigger(self, room_trigger):
        trig = Trigger.from_text(room_trigger)

        assert trig.id == 3004
        assert trig.attach_type.note == "WLD"
        # 'h' is letter-bit 7 -> WTRIG_DROP (1 << 7 == 128)
        assert trig.trigger_types[0].value == 128
        assert trig.trigger_types[0].note == "DROP"
        assert trig.commands == "* dump room script"

    def test_vnum_prefix_hash_tolerated(self, greet_trigger):
        # from_text should accept the vnum with or without a leading '#'.
        trig = Trigger.from_text("#" + greet_trigger)
        assert trig.id == 3098
