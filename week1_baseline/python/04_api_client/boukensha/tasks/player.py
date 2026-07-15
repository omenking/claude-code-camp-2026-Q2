from .base import Base


class Player(Base):
    @classmethod
    def task_name(cls):
        return "player"
