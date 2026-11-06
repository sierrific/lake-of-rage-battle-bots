"""Mecânicas de prioridade e de Fake Out que as regras (rules.py) têm de respeitar (plano de regressão de 06/11).

As regras tiram da busca as jogadas que com certeza falham. Estes casos conferem que elas não tiram
uma jogada que funciona, nem deixam uma que falha:

  - Fake Out só no primeiro turno em campo desde a última entrada (uma volta ao campo renova; o
    número do turno da partida não importa);
  - Fake Out (Normal) não afeta Ghost; afeta quem não é Ghost;
  - Psychic Terrain bloqueia prioridade só contra alvo no chão (grounded);
  - Armor Tail / Queenly Majesty / Dazzling bloqueiam prioridade contra os dois do lado de quem tem;
  - Prankster dá +1 só a golpes de status, e só esses falham em Dark: Fake Out de um Prankster
    acerta um Dark, com prioridade +3; Protect (+4) continua antes de Fake Out.

Roda sem torch nem poke-env: o rules.py do Ai-vgc com o patch, com o poke-env simulado.

    python3 mecanicas_prioridade.py src/ai_vgc/nn/rules.py
"""
import sys
import types
import unittest
from pathlib import Path
from types import SimpleNamespace as NS

RULES = Path(sys.argv.pop(1)).resolve()


class _Names(type):
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
    sys.modules.update({"poke_env": types.ModuleType("poke_env"), "poke_env.battle": battle,
                        "poke_env.battle.effect": effect, "poke_env.battle.target": target,
                        "poke_env.data": data})
    ns = {"__name__": "rules", "__file__": str(RULES)}
    exec(compile(RULES.read_text(encoding="utf-8"), str(RULES), "exec"), ns)
    return ns


R = load_rules()
T, C, TY, F = R["Target"], R["MoveCategory"], R["PokemonType"], R["Field"]
IMMUNE = {(TY.NORMAL, TY.GHOST), (TY.FIGHTING, TY.GHOST), (TY.GHOST, TY.NORMAL), (TY.PSYCHIC, TY.DARK),
          (TY.GROUND, TY.FLYING), (TY.ELECTRIC, TY.GROUND)}


def move(id, type, *, category=None, priority=0, power=40, flags=(), target=None):
    return NS(id=id, type=type, category=category or C.PHYSICAL, priority=priority, base_power=power,
              accuracy=100, flags=set(flags), target=target or T.NORMAL, secondary=[], status=None,
              volatile_status=None, boosts=None, self_boost=None, recoil=0, self_destruct=None, drain=0,
              n_hit=(1, 1), heal=0, side_condition=None)


FAKE_OUT = move("fakeout", TY.NORMAL, priority=3, flags={"contact"})
FIRST_IMPRESSION = move("firstimpression", TY.BUG, priority=2, power=90, flags={"contact"})
QUICK_ATTACK = move("quickattack", TY.NORMAL, priority=1, flags={"contact"})
GRASSY_GLIDE = move("grassyglide", TY.GRASS, power=55, flags={"contact"})
THUNDER_WAVE = move("thunderwave", TY.ELECTRIC, category=C.STATUS)
PROTECT = move("protect", TY.NORMAL, category=C.STATUS, priority=4, target=T.SELF)
TAILWIND = move("tailwind", TY.FLYING, category=C.STATUS, target=T.ALLIES)
TACKLE = move("tackle", TY.NORMAL)


def mon(species, types_, ability="", *, first_turn=False, item="", hp=1.0):
    m = NS(species=species, base_species=species, types=list(types_), ability=ability, possible_abilities=[],
           item=item, fainted=False, effects={}, forme_change_ability=None, moves={}, first_turn=first_turn,
           current_hp_fraction=hp, status=None, boosts={}, protect_counter=0)
    m.damage_multiplier = lambda mv, m=m: 0 if any((mv.type, t) in IMMUNE for t in m.types) else 1
    return m


def battle(user, foes, *, ally=None, fields=()):
    ally = ally or mon("amoonguss", [TY.GRASS, TY.POISON], "regenerator")
    foes = list(foes) + [None] * (2 - len(foes))
    grounded = lambda m: TY.FLYING not in m.types and m.ability != "levitate" and m.item != "airballoon"
    return NS(active_pokemon=[user, ally], opponent_active_pokemon=foes,
              team={f"p1: {m.species}": m for m in (user, ally)},
              opponent_team={f"p2: {m.species}": m for m in foes if m is not None},
              fields={f: 1 for f in fields}, weather={}, side_conditions={}, opponent_side_conditions={},
              is_grounded=grounded, opponent_used_mega_evolve=True, can_mega_evolve=[False, False],
              OPPONENT_1_POSITION=1, OPPONENT_2_POSITION=2, POKEMON_1_POSITION=-1, POKEMON_2_POSITION=-2,
              EMPTY_TARGET_POSITION=0)


def blocked(b, user, mv, tgt):
    foes = [m for m in b.opponent_active_pokemon if m is not None]
    return R["foe_blocked"](b, user, b.active_pokemon[1], foes, mv, tgt, single=True)


def incineroar():
    return mon("incineroar", [TY.FIRE, TY.DARK], "intimidate")


def rillaboom():
    return mon("rillaboom", [TY.GRASS], "grassysurge")


class TestJanelaDoFakeOut(unittest.TestCase):
    """R02: a regra lê `first_turn` (primeira ação desde a última entrada), não o turno da partida."""

    def test_primeira_acao_em_campo_pode_usar(self):
        for turno in (1, 5):  # um lead no T1 ou quem voltou ao campo no T4 e age no T5
            user = mon("raichu", [TY.ELECTRIC], "lightningrod", first_turn=True)
            b = battle(user, [incineroar(), rillaboom()])
            b.turn = turno
            self.assertIsNone(R["move_fails"](b, 0, FAKE_OUT, 1), turno)

    def test_depois_da_primeira_acao_falha(self):
        user = mon("raichu", [TY.ELECTRIC], "lightningrod", first_turn=False)
        b = battle(user, [incineroar(), rillaboom()])
        b.turn = 1  # o turno da partida não renova a janela
        for mv in (FAKE_OUT, FIRST_IMPRESSION):
            self.assertEqual(R["move_fails"](b, 0, mv, 1), "not the first turn out", mv.id)

    def test_outros_golpes_nao_dependem_da_janela(self):
        user = mon("raichu", [TY.ELECTRIC], "lightningrod", first_turn=False)
        self.assertIsNone(R["move_fails"](battle(user, [incineroar(), rillaboom()]), 0, QUICK_ATTACK, 1))

    def test_ameaca_de_prioridade_do_adversario_usa_a_mesma_janela(self):
        # Quick Guard: um Fake Out do adversário só conta no primeiro turno dele em campo.
        for first, esperado in ((True, True), (False, False)):
            foe = incineroar()
            foe.first_turn = first
            foe.moves = {m.id: m for m in (FAKE_OUT, TACKLE, move("flareblitz", TY.FIRE), PROTECT)}
            self.assertEqual(R["_priority_threat"](battle(rillaboom(), [foe]), [foe]), esperado, first)


class TestFakeOutEmGhost(unittest.TestCase):
    """R03: Fake Out é Normal; Ghost é imune, quem não é Ghost não."""

    def test_ghost_e_imune(self):
        user = incineroar()
        user.first_turn = True
        for ghost in (mon("gholdengo", [TY.STEEL, TY.GHOST], "goodasgold"),
                      mon("basculegion", [TY.WATER, TY.GHOST], "swiftswim")):
            b = battle(user, [ghost, mon("kingambit", [TY.DARK, TY.STEEL], "defiant")])
            self.assertEqual(blocked(b, user, FAKE_OUT, ghost), "type immunity", ghost.species)

    def test_quem_nao_e_ghost_toma(self):
        user = incineroar()
        user.first_turn = True
        kingambit = mon("kingambit", [TY.DARK, TY.STEEL], "defiant")
        b = battle(user, [kingambit, mon("basculegion", [TY.WATER, TY.GHOST], "swiftswim")])
        self.assertIsNone(blocked(b, user, FAKE_OUT, kingambit))

    def test_scrappy_acerta_ghost(self):
        user = mon("kangaskhan", [TY.NORMAL], "scrappy", first_turn=True)
        ghost = mon("gholdengo", [TY.STEEL, TY.GHOST], "goodasgold")
        self.assertIsNone(blocked(battle(user, [ghost]), user, FAKE_OUT, ghost))


class TestPsychicTerrain(unittest.TestCase):
    """R04: Psychic Terrain bloqueia prioridade só contra alvo no chão."""

    def test_bloqueia_alvo_no_chao(self):
        user = incineroar()
        user.first_turn = True
        for tgt in (mon("indeedee", [TY.PSYCHIC, TY.NORMAL], "psychicsurge"),
                    mon("gardevoir", [TY.PSYCHIC, TY.FAIRY], "trace")):
            b = battle(user, [tgt], fields=[F.PSYCHIC_TERRAIN])
            self.assertEqual(blocked(b, user, FAKE_OUT, tgt), "priority into Psychic Terrain", tgt.species)

    def test_nao_bloqueia_alvo_fora_do_chao(self):
        user = incineroar()
        user.first_turn = True
        for tgt in (mon("pelipper", [TY.WATER, TY.FLYING], "drizzle"),
                    mon("bronzong", [TY.STEEL, TY.PSYCHIC], "levitate"),
                    mon("gardevoir", [TY.PSYCHIC, TY.FAIRY], "trace", item="airballoon")):
            b = battle(user, [tgt], fields=[F.PSYCHIC_TERRAIN])
            self.assertIsNone(blocked(b, user, FAKE_OUT, tgt), tgt.species)

    def test_sem_terreno_ou_sem_prioridade_nao_bloqueia(self):
        user = incineroar()
        user.first_turn = True
        tgt = mon("gardevoir", [TY.PSYCHIC, TY.FAIRY], "trace")
        self.assertIsNone(blocked(battle(user, [tgt]), user, FAKE_OUT, tgt))
        terreno = battle(user, [tgt], fields=[F.PSYCHIC_TERRAIN])
        self.assertIsNone(blocked(terreno, user, TACKLE, tgt))

    def test_grassy_glide_so_tem_prioridade_no_grassy_terrain(self):
        user = rillaboom()
        tgt = mon("gardevoir", [TY.PSYCHIC, TY.FAIRY], "trace")
        self.assertIsNone(blocked(battle(user, [tgt], fields=[F.PSYCHIC_TERRAIN]), user, GRASSY_GLIDE, tgt))
        ambos = battle(user, [tgt], fields=[F.PSYCHIC_TERRAIN, F.GRASSY_TERRAIN])
        self.assertEqual(blocked(ambos, user, GRASSY_GLIDE, tgt), "priority into Psychic Terrain")


class TestArmorTail(unittest.TestCase):
    """R05: Armor Tail (e Queenly Majesty / Dazzling) protege os dois do lado de quem tem."""

    def test_protege_os_dois_alvos(self):
        user = incineroar()
        user.first_turn = True
        for blocker in ("armortail", "queenlymajesty", "dazzling"):
            farigiraf = mon("farigiraf", [TY.NORMAL, TY.PSYCHIC], blocker)
            partner = rillaboom()
            b = battle(user, [farigiraf, partner])
            for tgt in (farigiraf, partner):
                self.assertEqual(blocked(b, user, FAKE_OUT, tgt),
                                 "priority into Armor Tail / Dazzling / Queenly Majesty", (blocker, tgt.species))

    def test_status_com_prankster_tambem_e_bloqueado(self):
        user = mon("whimsicott", [TY.GRASS, TY.FAIRY], "prankster")
        partner = rillaboom()
        b = battle(user, [mon("farigiraf", [TY.NORMAL, TY.PSYCHIC], "armortail"), partner])
        self.assertIsNotNone(blocked(b, user, THUNDER_WAVE, partner))

    def test_sem_a_habilidade_volta_a_funcionar(self):
        user = incineroar()
        user.first_turn = True
        farigiraf = mon("farigiraf", [TY.NORMAL, TY.PSYCHIC], "sapsipper")
        partner = rillaboom()
        b = battle(user, [farigiraf, partner])
        for tgt in (farigiraf, partner):
            self.assertIsNone(blocked(b, user, FAKE_OUT, tgt), tgt.species)

    def test_mold_breaker_ignora(self):
        user = mon("excadrill", [TY.GROUND, TY.STEEL], "moldbreaker", first_turn=True)
        farigiraf = mon("farigiraf", [TY.NORMAL, TY.PSYCHIC], "armortail")
        partner = rillaboom()
        self.assertIsNone(blocked(battle(user, [farigiraf, partner]), user, FAKE_OUT, partner))


class TestPranksterEDark(unittest.TestCase):
    """R06: Prankster só mexe em golpes de status."""

    def test_fake_out_de_prankster_acerta_dark(self):
        meowstic = mon("meowstic", [TY.PSYCHIC], "prankster", first_turn=True)
        grimmsnarl = mon("grimmsnarl", [TY.DARK, TY.FAIRY], "prankster")
        b = battle(meowstic, [grimmsnarl])
        self.assertIsNone(blocked(b, meowstic, FAKE_OUT, grimmsnarl))
        self.assertIsNone(R["move_fails"](b, 0, FAKE_OUT, 1))

    def test_status_de_prankster_falha_em_dark(self):
        meowstic = mon("meowstic", [TY.PSYCHIC], "prankster")
        grimmsnarl = mon("grimmsnarl", [TY.DARK, TY.FAIRY], "prankster")
        self.assertEqual(blocked(battle(meowstic, [grimmsnarl]), meowstic, THUNDER_WAVE, grimmsnarl),
                         "Prankster into a Dark type")

    def test_prioridades(self):
        prankster = mon("meowstic", [TY.PSYCHIC], "prankster", first_turn=True)
        comum = mon("incineroar", [TY.FIRE, TY.DARK], "intimidate", first_turn=True)
        b = battle(prankster, [rillaboom()])
        prio = lambda user, mv: R["effective_priority"](b, user, mv)
        self.assertEqual(prio(prankster, FAKE_OUT), 3)  # golpe físico: Prankster não soma
        self.assertEqual(prio(comum, FAKE_OUT), 3)
        self.assertEqual(prio(prankster, TAILWIND), 1)
        self.assertEqual(prio(comum, PROTECT), 4)
        self.assertEqual(prio(prankster, PROTECT), 5)
        self.assertGreater(prio(comum, PROTECT), prio(prankster, FAKE_OUT))


class TestAlvoNoParceiroDesmaiado(unittest.TestCase):
    """Golpe de um alvo no slot do parceiro quando o parceiro já desmaiou e não há reposição: o
    Showdown manda o golpe para lugar nenhum ([notarget]); só um slot adversário vazio é
    redirecionado. A regra tem de tirar esse alvo, sem mexer nos alvos adversários."""

    def setUp(self):
        self.basculegion = mon("basculegion", [TY.WATER, TY.GHOST], "adaptability")
        caido = mon("archaludon", [TY.STEEL, TY.DRAGON], "stamina")
        caido.fainted = True
        self.b = battle(self.basculegion, [mon("gardevoir", [TY.PSYCHIC, TY.FAIRY], "trace"),
                                           mon("raichu", [TY.ELECTRIC], "lightningrod")], ally=caido)
        # O nosso Pokémon vivo está no slot b (posição 1); o parceiro desmaiado ficou no slot a.
        self.b.active_pokemon = [caido, self.basculegion]
        self.golpe = move("lastrespects", TY.GHOST, power=50)

    def test_slot_do_parceiro_desmaiado_e_bloqueado(self):
        self.assertEqual(R["move_fails"](self.b, 1, self.golpe, -1), "no partner in that slot")

    def test_slot_vazio_tambem(self):
        self.b.active_pokemon = [None, self.basculegion]
        self.assertEqual(R["move_fails"](self.b, 1, self.golpe, -1), "no partner in that slot")

    def test_alvos_adversarios_continuam(self):
        for alvo in (1, 2):
            self.assertIsNone(R["move_fails"](self.b, 1, self.golpe, alvo), alvo)

    def test_parceiro_vivo_continua_alvo_valido(self):
        vivo = mon("archaludon", [TY.STEEL, TY.DRAGON], "stamina")
        self.b.active_pokemon = [vivo, self.basculegion]
        self.assertIsNone(R["move_fails"](self.b, 1, move("pollenpuff", TY.BUG, category=C.SPECIAL), -1))


if __name__ == "__main__":
    unittest.main()
