"""Replacement dependencies used by the lab (referenced from components/*.toml).
Adapt the shape to what `app.modules.identity` really returns (see `lab inspect`)."""
from types import SimpleNamespace


async def fake_user():
    return SimpleNamespace(id="00000000-0000-0000-0000-000000000001", email="lab@local",
                           is_active=True, is_admin=True, permissions=["*"])
