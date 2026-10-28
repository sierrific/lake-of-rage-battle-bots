#!/usr/bin/env python3
"""Ajusta o modelo do oponente da busca (cabeça "opp" do all-bo3-opp-v2) com os jogos coletados.

A busca do bot joga cada candidata contra as respostas mais prováveis do adversário, e quem diz
quais são é a cabeça do oponente de --opp-model. Ela foi treinada com jogos de humanos em geral;
aqui ela aprende como a ladder joga contra o nosso bot. Só se usa a visão do nosso bot (é a
mesma que a busca vê na hora de jogar), e só os rótulos do oponente: as jogadas do próprio bot
ficam de fora (imitar a si mesmo não ensina nada).

Roda na pasta do Ai-vgc, com o ambiente dele (no PC: /opt/lor-bots/ai-vgc, usuário bots):

    UV_NO_SYNC=1 uv run python treino-oponente.py dados --backup /mnt/c/Users/Thiago/LoR-backup-coleta --out data/lor-opp
    UV_NO_SYNC=1 uv run python treino-oponente.py treinar --data data/lor-opp/treino --out data/models/lor-opp-v1.pt
    UV_NO_SYNC=1 uv run python -m ai_vgc.nn.opp_eval data/models/all-bo3-opp-v2.pt data/models/lor-opp-v1.pt \\
        --data data/lor-opp/teste --val-frac 1

dados: lê <backup>/*/games.jsonl (uma linha por partida, com o log completo), ordena as séries pela
hora do primeiro jogo e guarda as mais antigas em <out>/treino e as mais novas (--teste) em
<out>/teste, um .npz por formato, no formato do ai_vgc.nn.dataset. Uma série nunca fica dividida.

treinar: parte de --init e guarda em --out o melhor checkpoint pela perda da cabeça do oponente
numa parte do treino separada por jogo (--val-frac), só se for melhor que o --init.
"""

from __future__ import annotations

import argparse
import json
import math
import multiprocessing
import os
import time
import zlib
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

KEYS = ["tok_cat", "tok_num", "mv_cat", "mv_dyn", "dmg", "glob", "act_tok", "mask",
        "ser_tok", "ser_mv", "ser_glob"]


def _limpa(log: str) -> str:
    # Como o player._add_log: os logs de treino começam no primeiro "|j|".
    linhas = log.split("\n")
    ini = next((i for i, x in enumerate(linhas) if x.startswith("|j|")), 0)
    return "\n".join(linhas[ini:])


def _jogo(item: tuple[str, str, str, list[str]]) -> dict[str, np.ndarray] | None:
    """Um jogo pela visão do nosso bot; item = (tag, log, nosso usuário, logs dos jogos anteriores
    da série)."""
    from poke_env import to_id_str

    from ai_vgc.nn.encode import encode
    from ai_vgc.nn.replay import player_info, replay, winner
    from ai_vgc.nn.series import Context

    tag, log, usuario, antes = item
    try:
        venc = winner(log)
        nomes = {r: player_info(log, r) for r in ("p1", "p2")}
    except Exception:
        return None
    papel = next((r for r, (n, _) in nomes.items() if to_id_str(n) == to_id_str(usuario)), None)
    if venc is None or papel is None:
        return None
    nome, rating = nomes[papel]
    eles = nomes["p2" if papel == "p1" else "p1"][0]
    ctx = Context.of(antes, nome, eles)
    rows: dict[str, list] = {k: [] for k in KEYS + ["preview", "turn", "opp"]}

    def cb(battle, action, preview, opp):
        battle._series = ctx
        e = encode(battle, rating)
        for k in KEYS:
            rows[k].append(e[k])
        rows["preview"].append(preview)
        rows["turn"].append(battle.turn)
        rows["opp"].append(opp)

    try:
        replay(tag, log, papel, cb)
    except Exception:
        return None
    n = len(rows["opp"])
    if not n:
        return None
    out = {k: np.stack(rows[k]) for k in KEYS}
    out["action"] = np.full((n, 2), -1, np.int16)  # as jogadas do próprio bot não entram
    out["preview"] = np.asarray(rows["preview"], bool)
    out["opp"] = np.stack(rows["opp"]).astype(np.int8)
    turns = np.asarray(rows["turn"], np.int16)
    out["rating"] = np.full(n, rating, np.int16)
    out["won"] = np.full(n, to_id_str(nome) == to_id_str(venc), bool)
    out["turns_left"] = turns.max(initial=0) - turns
    out["game"] = np.full(n, zlib.crc32(tag.encode()), np.uint32)
    return out


def _lote(itens):
    partes = [g for g in map(_jogo, itens) if g is not None]
    return {k: np.concatenate([p[k] for p in partes]) for k in partes[0]} if partes else None


def _ler_backup(backup: Path) -> dict[str, dict]:
    """Partidas únicas (pela tag) de <backup>/*/games.jsonl; linhas quebradas ou incompletas ficam de fora."""
    jogos: dict[str, dict] = {}
    for arq in sorted(backup.glob("*/games.jsonl")):
        with open(arq, encoding="utf-8", errors="replace") as f:
            for linha in f:
                try:
                    row = json.loads(linha)
                except ValueError:
                    continue
                if not isinstance(row, dict) or not all(isinstance(row.get(k), str) and row[k]
                                                        for k in ("log", "tag", "user", "format")):
                    continue
                jogos.setdefault(row["tag"].removeprefix("battle-"), row)
    return jogos


def _contexto(serie: list[tuple[int, str]], jogos: dict[str, dict]) -> list[tuple[str, list[str]]]:
    """(tag, logs dos jogos anteriores) de cada jogo da série, na ordem. Sem algum jogo anterior no
    backup (só o jogo 2, ou o 1 e o 3), o jogo vai sem contexto, como no dataset.py."""
    num = dict(serie)
    saida = []
    for n, tag in sorted(serie):
        anteriores = range(1, n)
        antes = [jogos[num[i]]["log"] for i in anteriores] if all(i in num for i in anteriores) else []
        saida.append((tag, antes))
    return saida


def dados(args) -> None:
    from ai_vgc.nn.encode import vocab
    from ai_vgc.nn.series import series_key

    vocab()
    jogos = _ler_backup(args.backup)
    print(f"{len(jogos)} jogos únicos em {args.backup}", flush=True)
    # Agrupa em séries (um jogo solto é uma série de um) e ordena pela hora do primeiro jogo.
    series: dict[str, list[tuple[int, str]]] = {}
    for tag, row in jogos.items():
        row["log"] = _limpa(row["log"])
        chave = series_key(row["log"])
        series.setdefault(chave[0] if chave else tag, []).append((chave[1] if chave else 1, tag))
    ordem = sorted(series.values(), key=lambda s: min(str(jogos[t].get("time", "")) for _, t in s))
    corte = int(round(len(ordem) * (1 - args.teste)))
    for nome, parte in (("treino", ordem[:corte]), ("teste", ordem[corte:])):
        por_formato: dict[str, list] = {}
        for s in parte:
            for tag, antes in _contexto(s, jogos):
                row = jogos[tag]
                por_formato.setdefault(row["format"], []).append((tag, row["log"], row["user"], antes))
        for fmt, itens in sorted(por_formato.items()):
            lotes = [itens[i:i + 50] for i in range(0, len(itens), 50)]
            t = time.time()
            # "spawn" pelo mesmo motivo do dataset.py (o loop do poke-env não sobrevive a um fork).
            with ProcessPoolExecutor(args.workers, mp_context=multiprocessing.get_context("spawn")) as pool:
                partes = [p for p in pool.map(_lote, lotes) if p is not None]
            if not partes:
                print(f"  {nome}/{fmt}: nenhum jogo legível de {len(itens)}", flush=True)
                continue
            d = {k: np.concatenate([p[k] for p in partes]) for k in partes[0]}
            pasta = args.out / nome
            pasta.mkdir(parents=True, exist_ok=True)
            np.savez(pasta / f"{fmt}.npz", **d)
            rot = (d["opp"][..., 0] >= 0).sum()
            print(f"  {nome}/{fmt}: {len(np.unique(d['game']))} de {len(itens)} jogos, {len(d['opp'])} decisões, "
                  f"{rot} jogadas do oponente rotuladas, {time.time() - t:.0f}s", flush=True)


def treinar(args) -> None:
    import torch

    from ai_vgc.nn.encode import move_table
    from ai_vgc.nn.model import Policy
    from ai_vgc.nn.train import load, step

    torch.manual_seed(args.seed)
    torch.set_num_threads(args.threads)
    data = load(args.data)
    val = (data["game"].long() % 1000) < args.val_frac * 1000
    tem = (data["opp"][..., 0] >= 0).any(-1)
    tr, va = torch.nonzero(~val & tem)[:, 0], torch.nonzero(val & tem)[:, 0]
    ckpt = torch.load(args.init, map_location="cpu", weights_only=False)
    if not ckpt["config"].get("aux"):
        raise SystemExit(f"{args.init} não tem cabeça do oponente")
    model = Policy(ckpt["sizes"], move_table(), **ckpt["config"])
    model.load_state_dict(ckpt["state"])
    if args.so_cabeca:
        for nome, p in model.named_parameters():
            p.requires_grad = nome.startswith("opp_")
    params = [p for p in model.parameters() if p.requires_grad]
    print(f"{len(tr)} decisões de treino / {len(va)} de validação; treinando "
          f"{sum(p.numel() for p in params) / 1e6:.2f}M de {sum(p.numel() for p in model.parameters()) / 1e6:.2f}M "
          f"parâmetros, {args.threads} threads", flush=True)

    def perda_val() -> tuple[float, float]:
        model.eval()
        ce = hit = n = 0.0
        with torch.no_grad():
            for i in range(0, len(va), args.batch * 2):
                *_, aux_ce, aux_hit, aux_n = step(model, {k: v[va[i:i + args.batch * 2]] for k, v in data.items()},
                                                  True)
                ce, hit, n = ce + aux_ce.item(), hit + aux_hit.item(), n + aux_n.item()
        model.train()
        return ce / max(n, 1), hit / max(n, 1)

    melhor, acerto = perda_val()
    print(f"início ({args.init}): perda {melhor:.4f}, acerto do movimento {acerto:.1%}", flush=True)
    opt = torch.optim.AdamW(params, lr=args.lr, weight_decay=args.wd)
    passos = args.epochs * math.ceil(len(tr) / args.batch)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: 0.5 * (1 + math.cos(math.pi * min(s / passos, 1))))
    salvou = False
    args.out.parent.mkdir(parents=True, exist_ok=True)
    for ep in range(1, args.epochs + 1):
        t = time.time()
        perm = tr[torch.randperm(len(tr))]
        for i in range(0, len(perm), args.batch):
            *_, aux_ce, _, aux_n = step(model, {k: v[perm[i:i + args.batch]] for k, v in data.items()}, True)
            loss = aux_ce / aux_n.clamp(min=1)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(params, 1.0)
            opt.step()
            sched.step()
        p, a = perda_val()
        marca = ""
        if p < melhor:
            melhor, salvou, marca = p, True, " (salvo)"
            torch.save({"state": model.state_dict(), "config": model.config, "sizes": ckpt["sizes"],
                        "args": {k: str(v) for k, v in vars(args).items() if k != "func"}, "epoch": ep,
                        "init": str(args.init)}, args.out)
        print(f"época {ep}: perda {p:.4f}, acerto do movimento {a:.1%}, {time.time() - t:.0f}s{marca}", flush=True)
    if not salvou:
        print(f"nenhuma época ficou melhor que {args.init}; nada salvo", flush=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(required=True)
    d = sub.add_parser("dados", help="games.jsonl do backup -> .npz de treino e de teste")
    d.add_argument("--backup", type=Path, required=True, help="pasta com <membro>/games.jsonl")
    d.add_argument("--out", type=Path, default=Path("data/lor-opp"))
    d.add_argument("--teste", type=float, default=0.15, help="fração das séries mais novas para o teste")
    d.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    d.set_defaults(func=dados)
    t = sub.add_parser("treinar", help="ajuste fino da cabeça do oponente")
    t.add_argument("--data", type=Path, default=Path("data/lor-opp/treino"))
    t.add_argument("--init", type=Path, default=Path("data/models/all-bo3-opp-v2.pt"))
    t.add_argument("--out", type=Path, default=Path("data/models/lor-opp-v1.pt"))
    t.add_argument("--epochs", type=int, default=8)
    t.add_argument("--batch", type=int, default=256)
    t.add_argument("--lr", type=float, default=3e-5)
    t.add_argument("--wd", type=float, default=0.01)
    t.add_argument("--val-frac", type=float, default=0.1)
    t.add_argument("--so-cabeca", action="store_true", help="treina só a cabeça do oponente (opp_*)")
    t.add_argument("--threads", type=int, default=2, help="threads do torch (deixe CPU para o bot)")
    t.add_argument("--seed", type=int, default=0)
    t.set_defaults(func=treinar)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
