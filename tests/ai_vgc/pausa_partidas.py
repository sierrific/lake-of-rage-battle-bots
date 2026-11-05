"""Exercita a pausa entre partidas do ladder e o seu toggle, sem contas, rede ou PyTorch."""
import ast
import contextlib
import io
import os
import random
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == "ChallengeMixin")
method = next(n for n in mixin.body if isinstance(n, ast.AsyncFunctionDef) and n.name == "_ladder_pause")


class TestPausaEntrePartidas(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.flag = Path(tmp.name) / "bot.sem-pausa"
        env = patch.dict(os.environ, LOR_SKIP_PAUSE_FILE=str(self.flag))
        env.start()
        self.addCleanup(env.stop)
        self.elapsed = 0
        self.on_sleep = lambda: None

        async def sleep(seconds):
            self.elapsed += seconds
            self.on_sleep()

        ns = {"os": os, "random": random, "time": types.SimpleNamespace(time=lambda: self.elapsed),
              "asyncio": types.SimpleNamespace(sleep=AsyncMock(side_effect=sleep))}
        exec(compile(ast.Module(body=[method], type_ignores=[]), "player.py", "exec"), ns)
        self.bot = type("Bot", (), {"_ladder_pause": ns["_ladder_pause"], "LADDER_PAUSE": (60, 300)})()
        self.bot.stop_after_match = False
        self.bot.personality = types.SimpleNamespace(pause_seconds=lambda: 120)
        self.output = io.StringIO()
        stdout = contextlib.redirect_stdout(self.output)
        stdout.__enter__()
        self.addCleanup(stdout.__exit__, None, None, None)

    async def test_padrao_pausa_o_tempo_do_perfil(self):
        await self.bot._ladder_pause()
        self.assertEqual(self.elapsed, 120)
        self.assertIn("pausing 2.0 min", self.output.getvalue())

    async def test_sem_variavel_mantem_pausa(self):
        with patch.dict(os.environ, LOR_SKIP_PAUSE_FILE=""):
            await self.bot._ladder_pause()
        self.assertEqual(self.elapsed, 120)

    async def test_desligado_busca_logo(self):
        self.flag.touch()
        await self.bot._ladder_pause()
        self.assertEqual(self.elapsed, 0)
        self.assertNotIn("pausing", self.output.getvalue())

    async def test_desligar_durante_a_pausa_encerra_a_pausa(self):
        self.on_sleep = lambda: self.elapsed >= 10 and self.flag.touch()
        await self.bot._ladder_pause()
        self.assertEqual(self.elapsed, 10)
        self.assertIn("pause between matches disabled: searching now", self.output.getvalue())

    async def test_parada_pedida_nao_pausa(self):
        self.bot.stop_after_match = True
        await self.bot._ladder_pause()
        self.assertEqual(self.elapsed, 0)


if __name__ == "__main__":
    unittest.main()
