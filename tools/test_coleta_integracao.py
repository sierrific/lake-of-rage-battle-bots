"""Contrato com uma cópia local do LOR-SD-Server; nenhum acesso à VPS.

python3 tools/test_coleta_integracao.py /ai-vgc/src/ai_vgc/nn/player.py /LOR-SD-Server
O segundo repositório precisa conter o protocolo 2 da fila.
"""
import contextlib
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import test_coleta_lease as harness  # consome o caminho do player.py

sys.path.insert(0, str(Path(sys.argv.pop(1)).resolve() / "coleta"))
import contrato
import fila
import identidade


class IntegrationTests(unittest.IsolatedAsyncioTestCase):
    setUp = harness.LeaseTests.setUp

    def response(self, request, timeout):
        self.assertEqual(request.get_header("Authorization"), "Bearer synthetic")
        data = json.loads(request.data)
        key = identidade.servidor_id(data["servidor"]) + "|" + identidade.formato_id(data["formato"])
        operation = fila.pedir if data["acao"] == "pedir" else fila.liberar
        result = operation("membro", identidade.conta_id(data["conta"]), key, agora=self.clock,
                           protocolo=data["protocolo"], lease=data.get("lease"))
        return contextlib.closing(io.BytesIO(json.dumps(result).encode()))

    async def test_acquire_renew_restart_loss_and_fresh_acquisition(self):
        fila._vez.clear()
        fila._espera.clear()
        with patch("urllib.request.urlopen", side_effect=self.response):
            self.assertTrue(await self.bot._wait_turn())
            first = self.bot._turn_lease
            renewed = await self.bot._turn("pedir", lease=first)
            self.assertTrue(renewed["vez"])
            self.assertEqual(renewed["lease"], first)
            # Outra instância da mesma conta não possui o token.
            self.assertFalse((await self.bot._turn("pedir"))["vez"])
            self.assertFalse((await self.bot._turn("liberar"))["ok"])
            self.assertTrue((await self.bot._turn("pedir", lease=first))["vez"])
            fila._vez.clear()  # reinício da coleta invalida a posse
            await self.bot._renew_turn()
            self.assertFalse(self.bot._can_search())
            await self.bot._release_turn()
            self.assertTrue(await self.bot._wait_turn())
            self.assertNotEqual(self.bot._turn_lease, first)
            await self.bot._release_turn()
            self.assertFalse(fila._vez)

    async def test_produced_rows_are_accepted_and_origin_disambiguates_same_tag(self):
        await harness.LeaseTests.test_records_identify_public_private_and_local_servers_without_replays(self)
        rows = [contrato.validar(json.loads(line)) for line in
                (self.bot.save_dir / "games.jsonl").read_text().splitlines()]
        origins = [identidade.servidor_partida(row) for row in rows]
        self.assertEqual(origins, ["showdown", "showdown.sierverso.com.br:443", "localhost:8000"])
        self.assertEqual(len({identidade.identidade_partida(row) for row in rows}), 3)


if __name__ == "__main__":
    unittest.main()
