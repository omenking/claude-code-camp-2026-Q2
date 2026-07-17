class UnknownToolError(Exception):
    pass


class ApiError(Exception):
    pass


class LoopError(Exception):
    pass


class TurnCancelled(Exception):
    pass


class UnsupportedModelError(Exception):
    pass
