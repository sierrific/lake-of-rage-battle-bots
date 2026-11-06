"""Casos em que a poda de golpes de área dominados não pode tirar o golpe certo (revisão de 06/11).

A regra (rules.py, move_dominated) tira um golpe de área quando só há um adversário e o mesmo
Pokémon tem um golpe de um alvo do mesmo tipo, pelo menos tão forte e tão preciso (Heat Wave ao
lado de Weather Ball no sol). A revisão achou três casos em que o golpe de um alvo não é melhor:

  - Bulletproof no adversário bloqueia Weather Ball (é um golpe "bullet"), não Heat Wave;
  - Punk Rock (Toxtricity) deixa Overdrive (som, 80) mais forte que Thunderbolt (90);
  - uma troca (ou um golpe) do nosso parceiro, ou uma troca deles, pode mudar o clima antes do
    Weather Ball: Drizzle entrando, Cloud Nine...

Roda sem torch nem poke-env: o rules.py do Ai-vgc com o patch, com o poke-env simulado e
batalhas montadas à mão (SimpleNamespace).

    python3 golpe_dominado_casos.py src/ai_vgc/nn/rules.py
"""
import sys
import types
import unittest
from pathlib import Path
from types import SimpleNamespace as NS

RULES = Path(sys.argv.pop(1)).resolve()


class _Names(type):
    """PokemonType.FIRE, Target.NORMAL...: um valor por nome, criado quando pedido."""

    def __getattr__(cls, name):
        if name.startswith("__"):
            raise AttributeError(name)
        value = cls.__new__(cls)
        value.name = name
        setattr(cls, name, value)
        return value

    def __iter__(cls):
        return iter(())


def _enum(name):
    return _Names(name, (), {"__repr__": lambda self: f"{type(self).__name__}.{self.name}"})


def load_rules() -> dict:
    battle = types.ModuleType("poke_env.battle")
    for name in ("Field", "MoveCategory", "PokemonType", "SideCondition", "Status", "Weather"):
        setattr(battle, name, _enum(name))
    for name in ("DoubleBattle", "Move", "Pokemon"):
        setattr(battle, name, type(name, (), {}))
    effect = types.ModuleType("poke_env.battle.effect")
    effect.Effect = _enum("Effect")
    target = types.ModuleType("poke_env.battle.target")
    target.Target = _enum("Target")
    data = types.ModuleType("poke_env.data")
    data.GenData = NS(from_gen=lambda gen: NS(pokedex={}))
    data.to_id_str = lambda s: "".join(c for c in str(s).lower() if c.isalnum())
    poke_env = types.ModuleType("poke_env")
    sys.modules.update({"poke_env": poke_env, "poke_env.battle": battle, "poke_env.battle.effect": effect,
                        "poke_env.battle.target": target, "poke_env.data": data})
    ns = {"__name__": "rules", "__file__": str(RULES)}
    exec(compile(RULES.read_text(encoding="utf-8"), str(RULES), "exec"), ns)
    return ns


R = load_rules()
T, C, TY, W = R["Target"], R["MoveCategory"], R["PokemonType"], R["Weather"]


def move(id, type, power, *, target=None, accuracy=100, flags=(), secondary=()):
    return NS(id=id, type=type, base_power=power, accuracy=accuracy, target=target or T.NORMAL,
              category=C.SPECIAL, flags=set(flags), secondary=list(secondary), self_boost=None, recoil=0,
              self_destruct=None, drain=0, n_hit=(1, 1), priority=0)


def mon(species, ability="", moves=(), possible=(), item="", fainted=False):
    return NS(species=species, base_species=species, ability=ability, possible_abilities=list(possible),
              item=item, fainted=fainted, effects={}, forme_change_ability=None,
              moves={m.id: m for m in moves}, first_turn=False)


HEAT_WAVE = move("heatwave", TY.FIRE, 95, target=T.ALL_ADJACENT_FOES, accuracy=90, flags={"wind"},
                 secondary=[{"chance": 10, "status": "brn"}])
WEATHER_BALL = move("weatherball", TY.NORMAL, 50, flags={"bullet"})
OVERDRIVE = move("overdrive", TY.ELECTRIC, 80, target=T.ALL_ADJACENT_FOES, flags={"sound"})
THUNDERBOLT = move("thunderbolt", TY.ELECTRIC, 90, secondary=[{"chance": 10, "status": "par"}])


def battle(user, foe, *, ally=None, bench=(), foe_bench=(), weather=None):
    ally = ally or mon("incineroar", "intimidate")
    team = {f"p1: {m.species}": m for m in (user, ally, *bench)}
    opp = {f"p2: {m.species}": m for m in (foe, *foe_bench)}
    return NS(active_pokemon=[user, ally], opponent_active_pokemon=[foe, None], team=team, opponent_team=opp,
              weather={weather: 1} if weather else {}, opponent_used_mega_evolve=True,
              can_mega_evolve=[False, False], fields={})


def charizard():
    return mon("charizardmegay", "drought", [HEAT_WAVE, WEATHER_BALL], item="charizarditey")


def metagross():
    return mon("metagrossmega", "toughclaws", possible=["toughclaws"])


class TestCasosDaRevisao(unittest.TestCase):
    def test_base_sol_um_alvo_continua_podando_heat_wave(self):
        self.assertTrue(R["move_dominated"](battle(charizard(), metagross(), weather=W.SUNNYDAY),
                                            0, HEAT_WAVE, WEATHER_BALL))

    def test_bulletproof_bloqueia_weather_ball(self):
        for foe in (mon("kommoo", "bulletproof"),
                    mon("kommoo", "", possible=["bulletproof", "soundproof", "overcoat"])):
            b = battle(charizard(), foe, weather=W.SUNNYDAY)
            self.assertFalse(R["move_dominated"](b, 0, HEAT_WAVE, WEATHER_BALL), foe.possible_abilities)

    def test_punk_rock_deixa_overdrive_mais_forte(self):
        toxtricity = mon("toxtricity", "punkrock", [OVERDRIVE, THUNDERBOLT])
        self.assertFalse(R["move_dominated"](battle(toxtricity, metagross()), 0, OVERDRIVE, THUNDERBOLT))
        # Sem Punk Rock (Plus), Thunderbolt continua melhor que Overdrive contra um alvo só.
        plus = mon("toxtricity", "plus", [OVERDRIVE, THUNDERBOLT])
        self.assertTrue(R["move_dominated"](battle(plus, metagross()), 0, OVERDRIVE, THUNDERBOLT))

    def test_troca_do_parceiro_pode_mudar_o_clima(self):
        pelipper = mon("pelipper", "drizzle")
        b = battle(charizard(), metagross(), bench=[pelipper], weather=W.SUNNYDAY)
        self.assertFalse(R["move_dominated"](b, 0, HEAT_WAVE, WEATHER_BALL))
        cloud = battle(charizard(), metagross(), bench=[mon("golduck", "cloudnine")], weather=W.SUNNYDAY)
        self.assertFalse(R["move_dominated"](cloud, 0, HEAT_WAVE, WEATHER_BALL))
        # Um reserva que já desmaiou não troca.
        caido = battle(charizard(), metagross(), bench=[mon("pelipper", "drizzle", fainted=True)],
                       weather=W.SUNNYDAY)
        self.assertTrue(R["move_dominated"](caido, 0, HEAT_WAVE, WEATHER_BALL))

    def test_golpe_de_clima_do_parceiro(self):
        ally = mon("whimsicott", "prankster", [move("raindance", TY.WATER, 0)])
        b = battle(charizard(), metagross(), ally=ally, weather=W.SUNNYDAY)
        self.assertFalse(R["move_dominated"](b, 0, HEAT_WAVE, WEATHER_BALL))

    def test_reserva_do_adversario_pode_mudar_o_clima(self):
        b = battle(charizard(), metagross(), foe_bench=[mon("politoed", "", possible=["drizzle", "damp"])],
                   weather=W.SUNNYDAY)
        self.assertFalse(R["move_dominated"](b, 0, HEAT_WAVE, WEATHER_BALL))

    def test_para_raios_do_parceiro_puxa_o_golpe_de_um_alvo(self):
        ally = mon("raichu", "lightningrod")
        plus = mon("toxtricity", "plus", [OVERDRIVE, THUNDERBOLT])
        self.assertFalse(R["move_dominated"](battle(plus, metagross(), ally=ally), 0, OVERDRIVE, THUNDERBOLT))


if __name__ == "__main__":
    unittest.main()
