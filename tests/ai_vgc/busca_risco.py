"""Pontuação com risco na busca (--search-risk): a média contra as respostas prováveis do oponente,
menos uma parte da distância até a pior resposta que tem pelo menos `tau` de probabilidade.

Com risco 0 (o padrão) a nota é a média de antes. Com risco, uma jogada que ganha na média mas perde
feio para uma resposta de ~15% cai abaixo de uma jogada segura; respostas abaixo de `tau` não contam.

Roda sem torch nem poke-env: só a função risk_adjusted, tirada do search.py do Ai-vgc com o patch.

    python3 busca_risco.py src/ai_vgc/nn/search.py src/ai_vgc/nn/player.py
"""
import ast
import re
import sys
import unittest
from pathlib import Path

import numpy as np

SEARCH, PLAYER = (Path(a).read_text(encoding="utf-8") for a in sys.argv[1:3])
del sys.argv[1:3]
tree = ast.parse(SEARCH)
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "risk_adjusted")
ns = {"np": np}
exec(compile(ast.Module(body=[fn], type_ignores=[]), "risk_adjusted", "exec"), ns)
risk_adjusted = ns["risk_adjusted"]


class TestRisco(unittest.TestCase):
    # Linhas: nossas candidatas. Colunas: respostas do oponente.
    M = np.array([[0.90, 0.90, 0.85, 0.10],   # frágil: ótima na média, perde para a 4a resposta
                  [0.65, 0.65, 0.65, 0.60]])  # segura
    q = np.array([0.40, 0.30, 0.15, 0.15])

    def test_sem_risco_e_a_media(self):
        np.testing.assert_allclose(risk_adjusted(self.M, self.q), self.M @ self.q)
        np.testing.assert_allclose(risk_adjusted(self.M, self.q, 0.0, 0.08), self.M @ self.q)

    def test_com_risco_prefere_a_jogada_segura(self):
        self.assertEqual(int((self.M @ self.q).argmax()), 0)
        for risk in (0.3, 0.5):
            self.assertEqual(int(risk_adjusted(self.M, self.q, risk, 0.08).argmax()), 1, risk)

    def test_valor_ajustado(self):
        mean = self.M @ self.q
        worst = self.M.min(1)
        np.testing.assert_allclose(risk_adjusted(self.M, self.q, 0.5, 0.08), mean - 0.5 * (mean - worst))

    def test_resposta_improvavel_nao_conta(self):
        q = np.array([0.50, 0.30, 0.17, 0.03])  # a resposta que derruba a frágil tem 3%
        np.testing.assert_allclose(risk_adjusted(self.M, q, 0.5, 0.08),
                                   self.M @ q - 0.5 * np.maximum(self.M @ q - self.M[:, :3].min(1), 0))
        self.assertEqual(int(risk_adjusted(self.M, q, 0.5, 0.08).argmax()), 0)

    def test_nenhuma_resposta_provavel_fica_a_media(self):
        q = np.full(4, 0.25)
        np.testing.assert_allclose(risk_adjusted(self.M, q, 0.5, 0.30), self.M @ q)

    def test_nunca_acima_da_media(self):
        # Mesmo quando as respostas prováveis são todas melhores que a média (a massa ruim está
        # nas improváveis), a nota não sobe: é uma penalidade, nunca um bônus.
        rng = np.random.default_rng(0)
        for _ in range(200):
            M = rng.random((5, 6)); q = rng.dirichlet(np.ones(6))
            self.assertTrue(np.all(risk_adjusted(M, q, 0.4, 0.08) <= M @ q + 1e-12))


class TestLigacao(unittest.TestCase):
    """O padrão não muda o bot: opções com 0 e a nota da busca passando pela função."""

    def test_opcoes_com_padrao_zero(self):
        self.assertRegex(PLAYER, r'"--search-risk", type=float, default=0\.0')
        self.assertRegex(PLAYER, r'"--search-risk-tau", type=float, default=0\.08')
        self.assertEqual(len(re.findall(r"risk=args\.search_risk, risk_tau=args\.search_risk_tau", PLAYER)), 2)

    def test_busca_usa_a_funcao(self):
        self.assertIn("value += w * risk_adjusted(M, q, risk, risk_tau)", SEARCH)
        self.assertIn('d["score"] = risk_adjusted(d["M"], q, self.risk, self.risk_tau)', SEARCH)
        self.assertRegex(SEARCH, r"risk: float = 0\.0,\s+risk_tau: float = 0\.08\) -> tuple")


if __name__ == "__main__":
    unittest.main()
