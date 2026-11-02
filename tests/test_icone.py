import base64
import re
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent


class TestIconePainel(unittest.TestCase):
    def test_icone_embutido_igual_ao_arquivo(self):
        # O Painel.ps1 é um arquivo só (é o que o Atualizar baixa), então leva o .ico em base64.
        # Depois de rodar tools/gerar_icone.py, a constante precisa ser regravada junto.
        fonte = (RAIZ / 'windows' / 'Painel.ps1').read_text(encoding='utf-8-sig')
        achado = re.search(r"^\$IconePainel = '([A-Za-z0-9+/=]+)'$", fonte, re.M)
        self.assertIsNotNone(achado, 'Painel.ps1 sem $IconePainel')
        ico = (RAIZ / 'windows' / 'painel.ico').read_bytes()
        self.assertEqual(base64.b64decode(achado.group(1)), ico)
        self.assertEqual(ico[:4], b'\x00\x00\x01\x00', 'cabeçalho ICO')


if __name__ == '__main__':
    unittest.main()
