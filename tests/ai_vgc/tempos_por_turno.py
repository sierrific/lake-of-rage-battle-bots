"""Confere o tempo por decisão que o bot grava em games.jsonl ("tempos": [total s, nossa parte s]).

Tira só ChallengeMixin._cycle e _handle_battle_request do player.py do Ai-vgc já com o patch (sem
importar o resto, que precisa de torch e poke-env) e as roda contra um Player falso. O CI chama
depois de aplicar o patch:

    python3 tests/ai_vgc/tempos_por_turno.py /tmp/ai-vgc/src/ai_vgc/nn/player.py
"""

import ast
import asyncio
import sys
import textwrap
import time

arvore = ast.parse(open(sys.argv[1]).read())
mixin = next(n for n in arvore.body if isinstance(n, ast.ClassDef) and n.name == "ChallengeMixin")
partes = [n for n in mixin.body
          if (isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in ("_cycle", "_handle_battle_request", "_live_battle_request"))
          or (isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "MAX_CYCLES")]
assert len(partes) == 4, "patch sem helpers de tempo e pedido"
ns = {"time": time, "asyncio": asyncio, "AbstractBattle": object}
exec("class Mixin:\n" + "\n".join(textwrap.indent(ast.unparse(p), "    ") for p in partes), ns)


class Player:  # o poke-env: escolhe em 0,2 s, nada a escolher num pedido "wait"
    async def _handle_battle_request(self, battle, maybe_default_order=False):
        if not battle._wait:
            await asyncio.sleep(0.2)


class Bot(ns["Mixin"], Player):
    pass


class Batalha:
    battle_tag = "battle-x"
    _wait = False
    finished = False


async def main():
    bot, b = Bot(), Batalha()
    await bot._handle_battle_request(b)  # escolha de time
    await asyncio.sleep(1.0)  # o oponente pensa mais 1 s
    await bot._handle_battle_request(b)  # turno 1
    await bot._handle_battle_request(b, maybe_default_order=True)  # escolha inválida, refeita: mesmo ciclo
    b._wait = True
    await bot._handle_battle_request(b)  # só o oponente escolhe (troca forçada)
    await asyncio.sleep(0.5)
    b._wait = False
    await bot._handle_battle_request(b)
    ciclos = bot._cycle(b.battle_tag, time.monotonic())["cycles"]
    (t0, n0), (t1, n1), (t2, n2), (t3, n3) = ciclos
    assert 1.1 <= t0 <= 1.4 and 0.1 <= n0 <= 0.3, ciclos
    assert 0.3 <= t1 <= 0.6 and 0.3 <= n1 <= 0.6, ciclos  # a nova escolha conta como nossa
    assert 0.4 <= t2 <= 0.7 and n2 == 0.0, ciclos
    assert 0.1 <= t3 <= 0.3, ciclos
    print("ok", ciclos)


asyncio.run(main())
