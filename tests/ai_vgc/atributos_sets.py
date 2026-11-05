"""Os sets que a busca manda ao simulador levam os seis EVs e IVs (revisão de código de 05/11).

De 01/11 (v2026.11.01.17) a 05/11 os contadores da busca também se chamavam STATS e substituíam a
lista dos seis atributos: dict(zip(STATS, evs)) saía vazio e o simulador jogava todo adversário
com 0 EVs e 31 IVs. Roda sem torch nem poke-env: só _set, com o resto simulado.

    python3 atributos_sets.py src/ai_vgc/nn/search.py
"""
import ast
import sys
import types
import unittest
from collections import Counter
from pathlib import Path

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))


def top_level_names(tree: ast.Module) -> Counter:
    names: Counter = Counter()
    for node in tree.body:
        if isinstance(node, ast.Assign):
            targets = list(node.targets)
        elif isinstance(node, ast.AnnAssign):
            targets = [node.target]
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names[node.name] += 1
            continue
        else:
            continue
        while targets:  # a, b = ... too; f.x = ... (an attribute) doesn't rebind f
            target = targets.pop()
            if isinstance(target, ast.Name):
                names[target.id] += 1
            elif isinstance(target, (ast.Tuple, ast.List)):
                targets.extend(target.elts)
    return names


def stub_namespace() -> dict:
    """search.py's module-level assignments of STATS and the counters, plus _set, with stubs."""
    wanted = {"STATS", "SEARCH_STATS"}
    body = []
    for node in source.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any(isinstance(t, ast.Name) and t.id in wanted for t in targets):
                body.append(node)
        elif isinstance(node, ast.FunctionDef) and node.name == "_set":
            body.append(node)
    spread = ((4, 252, 0, 0, 0, 252), "Adamant", (31, 31, 31, 31, 31, 0))
    ns = {
        "Counter": Counter, "Pokemon": object,
        "_species": lambda mon: mon.species, "_base": lambda species: species,
        "_pokedex": lambda: {"garchomp": {"abilities": {"0": "Rough Skin"}}},
        "to_id_str": lambda s: "".join(c for c in s.lower() if c.isalnum()),
        "_item": lambda mon: mon.item,
        "set_posterior": lambda *a: [((None, None, None), 1.0)],
        "team_pool": lambda teams_dir: ({("garchomp", "lifeorb", "roughskin",
                                           frozenset(["earthquake", "dragonclaw", "protect", "rockslide"])): spread}, {}),
        "spread_prior": lambda base: None,
    }
    exec(compile(ast.Module(body=body, type_ignores=[]), "search.py", "exec"), ns)
    return ns


class TestAtributosDosSets(unittest.TestCase):
    def test_nenhum_nome_global_reatribuido(self):
        # Foi assim que os contadores apagaram a lista: um segundo "STATS = ..." no mesmo módulo.
        repetidos = [n for n, k in top_level_names(source).items() if k > 1]
        self.assertEqual(repetidos, [])

    def test_seis_evs_e_ivs_antes_e_depois_dos_contadores(self):
        ns = stub_namespace()
        self.assertEqual(list(ns["STATS"]), ["hp", "atk", "def", "spa", "spd", "spe"])
        mon = types.SimpleNamespace(species="garchomp", name="Garchomp", ability="roughskin", item="lifeorb",
                                    level=50, moves={m: None for m in ("earthquake", "dragonclaw", "protect", "rockslide")})
        esperado = ({"hp": 4, "atk": 252, "def": 0, "spa": 0, "spd": 0, "spe": 252},
                    {"hp": 31, "atk": 31, "def": 31, "spa": 31, "spd": 31, "spe": 0})
        s = ns["_set"](mon, "times")
        self.assertEqual((s["evs"], s["ivs"]), esperado)
        self.assertEqual(s["nature"], "Adamant")
        # Os contadores da busca (o resumo no fim da execução) não mexem nos atributos.
        counters = ns.get("SEARCH_STATS")
        self.assertIsInstance(counters, Counter)
        counters["escape_lines"] += 3
        counters["field_added"] += 1
        s = ns["_set"](mon, "times")
        self.assertEqual((s["evs"], s["ivs"]), esperado)


if __name__ == "__main__":
    unittest.main()
