"""Recusa de chat pelo Showdown: suspender saudações sem ocultar erros de batalha."""
import ast
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == "ChallengeMixin")
names = {"_chat_on", "_say_personality", "_handle_chat_restriction", "_handle_battle_message", "teampreview"}
methods = [n for n in mixin.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
assert len(methods) == len(names)
RESTRICTION = ("Due to spam from your internet provider, you can't speak except to staff. "
               "Logging into an account you've used a lot in the past will allow you to chat.")
ROOM = [">battle-test"]


class Engine:
    async def _handle_battle_message(self, messages):
        self.received.append(messages)

    async def teampreview(self, battle):
        return "/team 1234"


class TestChatRestriction(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.sleep = AsyncMock()
        ns = {"Engine": Engine, "AbstractBattle": object,
              "time": types.SimpleNamespace(monotonic=lambda: 0),
              "asyncio": types.SimpleNamespace(sleep=self.sleep)}
        cls = ast.parse("class Bot(Engine): pass").body[0]
        cls.body = methods
        exec(compile(ast.fix_missing_locations(ast.Module(body=[cls], type_ignores=[])), "player.py", "exec"), ns)
        self.bot_class = ns["Bot"]
        self.bot = self.bot_class()
        self.bot.chat = True
        self.bot.chat_off = None
        self.bot.timer = True
        self.bot.replay_url = "https://replay.pokemonshowdown.com/"
        self.bot.received = []
        self.bot._battles = {}
        self.bot.logger = Mock()
        self.bot.ps_client = types.SimpleNamespace(send_message=AsyncMock())
        self.bot._placar = Mock()
        self.bot._pace_decision = AsyncMock()
        self.battle = types.SimpleNamespace(battle_tag="battle-test", finished=False)

    async def test_recusa_suspende_chat_e_avisa_uma_vez_sem_repetir_envios(self):
        for _ in range(3):
            await self.bot._handle_battle_message([ROOM, ["", "error", RESTRICTION]])
        self.assertFalse(self.bot._chat_on())
        self.bot.logger.warning.assert_called_once_with("showdown chat restricted: %s", RESTRICTION)
        self.bot.logger.critical.assert_not_called()
        self.bot.ps_client.send_message.assert_not_awaited()
        self.assertEqual(self.bot.received, [])

    async def test_restrito_pula_glhf_mas_preserva_timer_e_escolha_do_time(self):
        self.bot._handle_chat_restriction(["", "error", RESTRICTION])
        self.assertEqual(await self.bot.teampreview(self.battle), "/team 1234")
        self.bot.ps_client.send_message.assert_awaited_once_with("/timer on", "battle-test")
        self.bot._pace_decision.assert_awaited_once()

    async def test_recusa_e_fim_no_mesmo_pacote_pulam_gg_mas_salvam_replay(self):
        win = ["", "win", "ContaTeste"]
        await self.bot._handle_battle_message([ROOM, ["", "error", RESTRICTION], win])
        self.bot.ps_client.send_message.assert_awaited_once_with("/savereplay silent", "battle-test")
        self.assertEqual(self.bot.received, [[ROOM, win]])

    async def test_pedidos_e_erros_de_escolha_seguem_para_o_cliente(self):
        request = ["", "request", '{"active":[]}']
        invalid = ["", "error", "[Invalid choice] Can't move: invalid target"]
        unknown = ["", "error", "Outro erro do servidor"]
        await self.bot._handle_battle_message([ROOM, ["", "error", RESTRICTION], request, invalid, unknown])
        self.assertEqual(self.bot.received, [[ROOM, request, invalid, unknown]])

    async def test_chat_de_jogador_nao_pode_acionar_restricao(self):
        chat = ["", "c", "Rival", RESTRICTION]
        await self.bot._handle_battle_message([ROOM, chat])
        self.assertTrue(self.bot._chat_on())
        self.assertEqual(self.bot.received, [[ROOM, chat]])
        self.bot.logger.warning.assert_not_called()

    async def test_sem_restricao_preserva_saudacoes_e_opcao_de_chat(self):
        await self.bot.teampreview(self.battle)
        await self.bot._handle_battle_message([ROOM, ["", "win", "ContaTeste"]])
        self.assertEqual([c.args[0] for c in self.bot.ps_client.send_message.await_args_list],
                         ["glhf", "/timer on", "gg wp", "/savereplay silent"])
        self.bot.chat = False
        self.assertFalse(self.bot._chat_on())

    async def test_restricao_nao_altera_preferencia_nem_contamina_outro_bot(self):
        self.bot._handle_chat_restriction(["", "error", RESTRICTION])
        self.assertTrue(self.bot.chat)
        other = self.bot_class()
        other.chat, other.chat_off = True, None
        self.assertTrue(other._chat_on())

    async def test_folhas_abertas_continuam_no_replay(self):
        self.bot._battles["battle-test"] = types.SimpleNamespace(_replay_data=[])
        sheet = ["", "showteam", "p1", "packed team"]
        await self.bot._handle_battle_message([ROOM, ["", "error", RESTRICTION], sheet])
        self.assertEqual(self.bot._battles["battle-test"]._replay_data, [sheet])


if __name__ == "__main__":
    unittest.main()
