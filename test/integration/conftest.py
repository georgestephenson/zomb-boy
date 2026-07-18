import pytest
from harness import Game


@pytest.fixture
def game():
    g = Game()
    yield g
    g.close()
