# Painel LoR Bots: liga, desliga e configura o bot da Lake of Rage que roda no WSL deste PC.
# Fala com o Linux pelo /opt/lor-bots/painel.sh (distribuição LoRBots).
#   Painel.ps1          abre a janela
#   Painel.ps1 -Ligar   só liga o bot e sai (usado ao iniciar o Windows)
# A janela é desenhada à mão (componentes em C# logo abaixo), com dois temas tirados dos
# modelos do Thiago: "Dragão" (vermelho e dourado) e "Lago" (azul e dourado); a escolha fica em skin.txt.
param([switch]$Ligar)

# Dados embutidos (um arquivo sÃ³, que o botÃ£o Atualizar baixa inteiro): os componentes da janela em
# C# (Windows PowerShell 5.1 compila sÃ³ C# 5) e os cabeÃ§alhos de windows/skins/*.jpg em base64.
$CodigoUI = @'
// Componentes do Painel LoR Bots (WinForms desenhado à mão, com temas). Compilado pelo
// Painel.ps1 com Add-Type, então só C# 5: nada de $"", ?. ou => em propriedades.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace LoR
{
    public class Tema
    {
        public string Id, Nome;
        public Color Fundo, Cartao, Borda, Texto, Suave, Sub, Ouro, SobreOuro, Neutro, Campo, CampoBorda,
            Verde, VerdeFundo, VerdeBorda, VerdeTexto, Vermelho, Ambar, Desligado, DesligadoTexto, Log,
            Escama, LinhaCabecalho, SimboloJanela, Pilula, PilulaBorda,
            Moldura, TextoContorno, LogBorda, ChaveTrilho, ChaveBolinha, PontoVerde;
        public float LarguraMoldura = 1f;
        public Color[] Cabecalho;
        public float[] CabecalhoPos;
        public Image Logo, ImagemCabecalho;
        public bool LogoNoMeio, LegendaAoLado;

        public static Tema Atual;
        public static float F = 1f; // escala de DPI

        public static int S(float v) { return (int)Math.Round(v * F); }

        public Color Cor(string nome)
        {
            switch (nome)
            {
                case "fundo": return Fundo;
                case "cartao": return Cartao;
                case "campo": return Campo;
                case "log": return Log;
                case "texto": return Texto;
                case "suave": return Suave;
                case "sub": return Sub;
                case "ouro": return Ouro;
                case "verde": return Verde;
                case "ponto": return PontoVerde;
                case "vermelho": return Vermelho;
                case "ambar": return Ambar;
                case "desligado": return DesligadoTexto;
                default: return Texto;
            }
        }
    }

    public interface ITematico { void AplicarTema(); }

    public static class Desenho
    {
        public static GraphicsPath Arredondado(RectangleF r, float raio)
        {
            var p = new GraphicsPath();
            float d = raio * 2;
            if (d <= 0) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static void Preparar(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        }

        public static Color Misturar(Color a, Color b, float t)
        {
            return Color.FromArgb(
                (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }

        public static Font Icones(float tamanho)
        {
            return new Font("Segoe MDL2 Assets", tamanho, FontStyle.Regular, GraphicsUnit.Point);
        }

        // Texto com a cor exata do tema (TextRenderer: nítido e com ClearType).
        public static void Texto(Graphics g, string s, Font f, Color c, Rectangle r, TextFormatFlags flags)
        {
            TextRenderer.DrawText(g, s, f, r, c, flags | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    // Cor de fundo herdada: o controle pinta o mesmo fundo do pai (cartão ou janela).
    public class Base : Control
    {
        public string FundoNome = "cartao";
        public Base()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        }
        protected Color CorFundo { get { return Tema.Atual.Cor(FundoNome); } }
        protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(CorFundo); }
    }

    public class Janela : Form, ITematico
    {
        public int AlturaCabecalho = 64;
        public string Subtitulo = "Painel do bot";
        Bitmap cabecalho;

        public Janela()
        {
            FormBorderStyle = FormBorderStyle.None;
            DoubleBuffered = true;
            SetStyle(ControlStyles.ResizeRedraw, true);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ClassStyle |= 0x20000;      // CS_DROPSHADOW
                cp.Style |= 0x20000;           // WS_MINIMIZEBOX: minimizar pela barra de tarefas
                return cp;
            }
        }

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int valor, int tamanho);

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try { int v = 2; DwmSetWindowAttribute(Handle, 33, ref v, 4); } catch { } // cantos redondos (Windows 11)
        }

        // Barra de título escura nas janelas comuns (o diálogo de adicionar time).
        public static void TituloEscuro(Form f)
        {
            f.HandleCreated += delegate { try { int v = 1; DwmSetWindowAttribute(f.Handle, 20, ref v, 4); } catch { } };
        }

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == 0x84 && (int)m.Result == 1) // WM_NCHITTEST, HTCLIENT
            {
                var p = PointToClient(new Point((short)(m.LParam.ToInt64() & 0xFFFF), (short)((m.LParam.ToInt64() >> 16) & 0xFFFF)));
                if (p.Y < AlturaCabecalho) m.Result = (IntPtr)2; // HTCAPTION: arrasta a janela
            }
        }

        public Bitmap Cabecalho
        {
            get
            {
                if (cabecalho == null || cabecalho.Width != ClientSize.Width) Gerar();
                return cabecalho;
            }
        }

        void Gerar()
        {
            if (cabecalho != null) cabecalho.Dispose();
            var t = Tema.Atual;
            int w = Math.Max(1, ClientSize.Width), h = AlturaCabecalho;
            cabecalho = new Bitmap(w, h);
            using (var g = Graphics.FromImage(cabecalho))
            {
                Desenho.Preparar(g);
                if (t.ImagemCabecalho != null)
                {
                    // Imagem recortada dos modelos: "cover", ancorada à esquerda e no topo.
                    float esc = Math.Max((float)h / t.ImagemCabecalho.Height, (float)w / t.ImagemCabecalho.Width);
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.DrawImage(t.ImagemCabecalho, 0, 0, t.ImagemCabecalho.Width * esc, t.ImagemCabecalho.Height * esc);
                    return;
                }
                var area = new Rectangle(0, 0, w, h);
                using (var lg = new LinearGradientBrush(area, t.Cabecalho[0], t.Cabecalho[t.Cabecalho.Length - 1], 0f))
                {
                    var cb = new ColorBlend();
                    cb.Colors = t.Cabecalho;
                    cb.Positions = t.CabecalhoPos;
                    lg.InterpolationColors = cb;
                    g.FillRectangle(lg, area);
                    // Escamas: círculos em fileiras alternadas, cada fileira cobrindo metade da anterior.
                    float r = Tema.S(13);
                    using (var traco = new Pen(t.Escama, Math.Max(1f, Tema.F * 1.2f)))
                    using (var brilho = new Pen(Color.FromArgb(28, 255, 255, 255), Math.Max(1f, Tema.F)))
                    {
                        int fila = 0;
                        for (float y = -r; y < h + r; y += r * 0.85f, fila++)
                        {
                            float x0 = (fila % 2 == 0) ? -r : 0;
                            for (float x = x0; x < w + 2 * r; x += 2 * r)
                            {
                                var c = new RectangleF(x - r, y - r, 2 * r, 2 * r);
                                g.FillEllipse(lg, c);
                                g.DrawArc(traco, c, 20, 140);
                                var d = RectangleF.Inflate(c, -3 * Tema.F, -3 * Tema.F);
                                g.DrawArc(brilho, d, 200, 140);
                            }
                        }
                    }
                }
                // Sombra suave embaixo, para o cabeçalho "assentar" sobre a janela.
                using (var sombra = new LinearGradientBrush(new Rectangle(0, h - Tema.S(14), w, Tema.S(14)),
                    Color.FromArgb(0, 0, 0, 0), Color.FromArgb(70, 0, 0, 0), 90f))
                    g.FillRectangle(sombra, 0, h - Tema.S(14), w, Tema.S(14));
                if (t.Logo != null)
                {
                    float lh = h - Tema.S(t.LogoNoMeio ? 6 : 16);
                    float lw = t.Logo.Width * lh / t.Logo.Height;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    if (t.LogoNoMeio)
                    {
                        // Clarão dourado atrás do logo.
                        using (var gp = new GraphicsPath())
                        {
                            var el = new RectangleF((w - lw * 1.6f) / 2, -h * 0.3f, lw * 1.6f, h * 1.6f);
                            gp.AddEllipse(el);
                            using (var pb = new PathGradientBrush(gp))
                            {
                                pb.CenterColor = Color.FromArgb(150, 245, 214, 130);
                                pb.SurroundColors = new[] { Color.FromArgb(0, 245, 214, 130) };
                                g.FillEllipse(pb, el);
                            }
                        }
                        g.DrawImage(t.Logo, (w - lw) / 2, (h - lh) / 2, lw, lh);
                    }
                    else
                    {
                        float x = Tema.S(18);
                        g.DrawImage(t.Logo, x, (h - lh) / 2, lw, lh);
                        float xs = x + lw + Tema.S(18);
                        using (var p = new Pen(Color.FromArgb(90, t.Texto), Math.Max(1f, Tema.F)))
                            g.DrawLine(p, xs, h * 0.3f, xs, h * 0.7f);
                        using (var f = new Font("Segoe UI", 13f))
                            Desenho.Texto(g, Subtitulo, f, Color.FromArgb(220, t.Texto),
                                new Rectangle((int)xs + Tema.S(16), 0, Tema.S(300), h), TextFormatFlags.VerticalCenter);
                    }
                }
                using (var p = new Pen(t.LinhaCabecalho, Math.Max(1f, 2 * Tema.F)))
                    g.DrawLine(p, 0, h - 1, w, h - 1);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            e.Graphics.Clear(t.Fundo);
            e.Graphics.DrawImageUnscaled(Cabecalho, 0, 0);
            float lm = Math.Max(1f, t.LarguraMoldura * Tema.F);
            using (var p = new Pen(t.Moldura, lm))
                e.Graphics.DrawRectangle(p, lm / 2, lm / 2, ClientSize.Width - lm, ClientSize.Height - lm);
        }

        protected override void OnResize(EventArgs e) { base.OnResize(e); Invalidate(); }

        public void AplicarTema()
        {
            if (cabecalho != null) { cabecalho.Dispose(); cabecalho = null; }
            BackColor = Tema.Atual.Fundo;
            Aplicar(Controls);
            Invalidate(true);
        }

        static void Aplicar(Control.ControlCollection cs)
        {
            foreach (Control c in cs)
            {
                var t = c as ITematico;
                if (t != null) t.AplicarTema();
                Aplicar(c.Controls);
                c.Invalidate();
            }
        }
    }

    // Botões do cabeçalho (tema, minimizar, fechar): desenham por cima da imagem do cabeçalho.
    public class BotaoJanela : Control
    {
        public string Simbolo = "";
        public bool Fechar;
        bool sobre;
        public BotaoJanela()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            Cursor = Cursors.Hand;
        }
        protected override void OnMouseEnter(EventArgs e) { sobre = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { sobre = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            var j = Parent as Janela;
            if (j != null) e.Graphics.DrawImage(j.Cabecalho, new Rectangle(0, 0, Width, Height), new Rectangle(Left, Top, Width, Height), GraphicsUnit.Pixel);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            var g = e.Graphics;
            Color cor = t.SimboloJanela;
            if (sobre)
            {
                using (var b = new SolidBrush(Fechar ? Color.FromArgb(220, 196, 43, 28) : Color.FromArgb(45, t.SimboloJanela)))
                    g.FillRectangle(b, ClientRectangle);
                if (Fechar) cor = Color.White;
            }
            using (var f = Desenho.Icones(10.5f))
                Desenho.Texto(g, Simbolo, f, cor, ClientRectangle, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }

    public class Cartao : Panel, ITematico
    {
        public string Titulo = "", Subtitulo = "";
        public Cartao()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }
        public void AplicarTema() { BackColor = Tema.Atual.Cartao; }
        protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(Tema.Atual.Fundo); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            var g = e.Graphics;
            Desenho.Preparar(g);
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (var p = Desenho.Arredondado(r, Tema.S(10)))
            using (var b = new SolidBrush(t.Cartao))
            using (var borda = new Pen(t.Borda, Math.Max(1f, Tema.F)))
            {
                g.FillPath(b, p);
                g.DrawPath(borda, p);
            }
            if (Titulo.Length > 0)
            {
                // Tema "lado": legenda à direita do título; senão, embaixo dele (e o título sobe um pouco).
                bool lado = t.LegendaAoLado || Subtitulo.Length == 0;
                using (var f = new Font("Segoe UI Semibold", 13f))
                    Desenho.Texto(g, Titulo, f, t.Texto, new Rectangle(Tema.S(20), Tema.S(lado ? 12 : 6), Width - Tema.S(40), Tema.S(30)), TextFormatFlags.Left);
                if (Subtitulo.Length > 0)
                    using (var f = new Font("Segoe UI", 9.5f))
                    {
                        if (lado)
                            Desenho.Texto(g, Subtitulo, f, t.Suave, new Rectangle(Tema.S(20), Tema.S(18), Width - Tema.S(40), Tema.S(22)), TextFormatFlags.Right);
                        else
                            Desenho.Texto(g, Subtitulo, f, t.Sub, new Rectangle(Tema.S(20), Tema.S(31), Width - Tema.S(40), Tema.S(20)), TextFormatFlags.Left);
                    }
            }
        }
    }

    public enum Estilo { Primario, Contorno, Neutro, Perigo, Fantasma }

    public class Botao : Base
    {
        public Estilo Estilo = Estilo.Contorno;
        public string Icone = "";
        public bool Negrito = true;
        bool sobre, apertado;
        public Botao() { Cursor = Cursors.Hand; }
        protected override void OnMouseEnter(EventArgs e) { sobre = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { sobre = false; apertado = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { apertado = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { apertado = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            var g = e.Graphics;
            Desenho.Preparar(g);
            Color fundo, borda, texto;
            if (!Enabled)
            {
                fundo = Estilo == Estilo.Fantasma ? CorFundo : t.Desligado;
                borda = Estilo == Estilo.Fantasma ? CorFundo : Desenho.Misturar(t.Desligado, t.Texto, 0.12f);
                texto = t.DesligadoTexto;
                if (Estilo == Estilo.Perigo) { fundo = CorFundo; borda = Color.FromArgb(90, t.Vermelho); texto = Color.FromArgb(120, t.Vermelho); }
            }
            else
            {
                switch (Estilo)
                {
                    case Estilo.Primario: fundo = t.Ouro; borda = t.Ouro; texto = t.SobreOuro; break;
                    case Estilo.Perigo: fundo = CorFundo; borda = t.Vermelho; texto = t.Vermelho; break;
                    case Estilo.Neutro: fundo = CorFundo; borda = t.Neutro; texto = t.Texto; break;
                    case Estilo.Fantasma: fundo = CorFundo; borda = CorFundo; texto = t.Texto; break;
                    default: fundo = CorFundo; borda = t.Ouro; texto = t.TextoContorno; break;
                }
                if (sobre)
                {
                    fundo = Estilo == Estilo.Primario ? Desenho.Misturar(fundo, Color.White, apertado ? 0.05f : 0.18f)
                        : Desenho.Misturar(fundo, borda, apertado ? 0.22f : 0.12f);
                }
            }
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (var p = Desenho.Arredondado(r, Tema.S(6)))
            using (var b = new SolidBrush(fundo))
            using (var pen = new Pen(borda, Math.Max(1f, Tema.F * 1.3f)))
            {
                g.FillPath(b, p);
                g.DrawPath(pen, p);
            }
            // Ícones do Segoe MDL2 (área de uso privado); ▶ e ■ cheios vêm do Segoe UI Symbol.
            bool mdl2 = Icone.Length > 0 && Icone[0] >= '';
            using (var f = new Font(Negrito ? "Segoe UI Semibold" : "Segoe UI", 10.5f))
            using (var fi = mdl2 ? Desenho.Icones(11f) : new Font("Segoe UI Symbol", 11f))
            {
                var tam = TextRenderer.MeasureText(g, Text, f, Size.Empty, TextFormatFlags.NoPadding);
                int iw = Icone.Length > 0 ? Tema.S(26) : 0;
                int x = (Width - tam.Width - iw) / 2;
                if (iw > 0)
                {
                    Color ci = texto;
                    if (Estilo == Estilo.Perigo && Enabled) ci = t.Vermelho;
                    Desenho.Texto(g, Icone, fi, ci, new Rectangle(x, 0, Tema.S(18), Height), TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
                }
                Desenho.Texto(g, Text, f, texto, new Rectangle(x + iw, 0, tam.Width + 4, Height), TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
            }
        }
    }

    // Texto simples com a cor do tema.
    public class Rotulo : Base
    {
        public string CorNome = "texto";
        public float Tamanho = 10f;
        public bool Negrito, Sublinhado, Mono;
        public TextFormatFlags Alinhar = TextFormatFlags.Left | TextFormatFlags.VerticalCenter;
        public Rotulo() { }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
        public Font Fonte()
        {
            var estilo = Sublinhado ? FontStyle.Underline : FontStyle.Regular;
            return new Font(Mono ? "Consolas" : (Negrito ? "Segoe UI Semibold" : "Segoe UI"), Tamanho, estilo);
        }
        public int LarguraTexto()
        {
            using (var f = Fonte()) return TextRenderer.MeasureText(Text, f, Size.Empty, TextFormatFlags.NoPadding).Width;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            using (var f = Fonte())
                Desenho.Texto(e.Graphics, Text, f, Tema.Atual.Cor(CorNome), ClientRectangle, Alinhar | TextFormatFlags.EndEllipsis);
        }
    }

    public class Icone : Base
    {
        public string CorNome = "suave";
        public float Tamanho = 11f;
        protected override void OnPaint(PaintEventArgs e)
        {
            using (var f = Desenho.Icones(Tamanho))
                Desenho.Texto(e.Graphics, Text, f, Tema.Atual.Cor(CorNome), ClientRectangle, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }

    public class Bolinha : Base
    {
        public string CorNome = "verde";
        public bool Brilho = true;
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            Desenho.Preparar(g);
            var c = Tema.Atual.Cor(CorNome);
            float m = Brilho ? Width * 0.18f : 0;
            if (Brilho)
                using (var b = new SolidBrush(Color.FromArgb(50, c))) g.FillEllipse(b, 0, 0, Width - 1, Height - 1);
            using (var b = new SolidBrush(c)) g.FillEllipse(b, m, m, Width - 1 - 2 * m, Height - 1 - 2 * m);
        }
    }

    // Etiqueta arredondada ("Partida em andamento", "1106 MB").
    public class Pilula : Base
    {
        public string Tipo = "verde"; // verde | neutra | ambar
        public string Simbolo = "";
        public int LarguraIdeal()
        {
            using (var f = new Font("Segoe UI", 10f))
                return TextRenderer.MeasureText(Text, f, Size.Empty, TextFormatFlags.NoPadding).Width + Tema.S(28) + (Simbolo.Length > 0 ? Tema.S(24) : 0);
        }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            var g = e.Graphics;
            Desenho.Preparar(g);
            Color fundo, borda, texto;
            if (Tipo == "verde") { fundo = t.VerdeFundo; borda = t.VerdeBorda; texto = t.VerdeTexto; }
            else if (Tipo == "ambar") { fundo = Color.FromArgb(40, t.Ambar); borda = Color.FromArgb(150, t.Ambar); texto = t.Ambar; }
            else { fundo = t.Pilula; borda = t.PilulaBorda; texto = t.Texto; }
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (var p = Desenho.Arredondado(r, Tema.S(6)))
            using (var b = new SolidBrush(Desenho.Misturar(CorFundo, Color.FromArgb(255, fundo), fundo.A / 255f)))
            using (var pen = new Pen(borda, Math.Max(1f, Tema.F)))
            {
                g.FillPath(b, p);
                g.DrawPath(pen, p);
            }
            int x = Tema.S(14);
            if (Simbolo.Length > 0)
            {
                using (var f = Desenho.Icones(10f))
                    Desenho.Texto(g, Simbolo, f, t.Suave, new Rectangle(x, 0, Tema.S(18), Height), TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
                x += Tema.S(24);
            }
            using (var f = new Font("Segoe UI", 10f))
                Desenho.Texto(g, Text, f, texto, new Rectangle(x, 0, Width - x, Height), TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
        }
    }

    // Caixa de texto com borda arredondada (a TextBox de verdade fica dentro, sem borda).
    public class Campo : Base, ITematico
    {
        public TextBox Caixa = new TextBox();
        public Icone Olho;
        bool foco;
        public Campo()
        {
            Caixa.BorderStyle = BorderStyle.None;
            Caixa.Font = new Font("Segoe UI", 11f);
            Controls.Add(Caixa);
            Caixa.GotFocus += delegate { foco = true; Invalidate(); };
            Caixa.LostFocus += delegate { foco = false; Invalidate(); };
            Cursor = Cursors.IBeam;
            Click += delegate { Caixa.Focus(); };
            AplicarTema();
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);

        string dica = "";
        public string Dica
        {
            get { return dica; }
            set { dica = value; if (Caixa.IsHandleCreated) SendMessage(Caixa.Handle, 0x1501, (IntPtr)1, dica); else Caixa.HandleCreated += delegate { SendMessage(Caixa.Handle, 0x1501, (IntPtr)1, dica); }; }
        }

        public void ComOlho()
        {
            Olho = new Icone();
            Olho.Text = "";
            Olho.Tamanho = 12f;
            Olho.FundoNome = "campo";
            Olho.Cursor = Cursors.Hand;
            Olho.Click += delegate { Caixa.UseSystemPasswordChar = !Caixa.UseSystemPasswordChar; Olho.CorNome = Caixa.UseSystemPasswordChar ? "suave" : "ouro"; Olho.Invalidate(); };
            Controls.Add(Olho);
            Caixa.UseSystemPasswordChar = true;
            Arrumar();
        }

        public void AplicarTema()
        {
            Caixa.BackColor = Tema.Atual.Campo;
            Caixa.ForeColor = Tema.Atual.Texto;
        }

        public void Multilinha()
        {
            Caixa.Multiline = true;
            Caixa.AcceptsReturn = true;
            Caixa.ScrollBars = ScrollBars.Vertical;
            Caixa.Font = new Font("Consolas", 10f);
            Caixa.HandleCreated += delegate { try { CaixaLog.TemaEscuro(Caixa.Handle); } catch { } };
            Arrumar();
        }

        void Arrumar()
        {
            int pad = Tema.S(14);
            int ow = Olho != null ? Tema.S(32) : 0;
            if (Caixa.Multiline) { Caixa.SetBounds(pad, Tema.S(10), Width - 2 * pad, Height - Tema.S(20)); return; }
            Caixa.Location = new Point(pad, (Height - Caixa.Height) / 2);
            Caixa.Width = Width - 2 * pad - ow;
            if (Olho != null) Olho.SetBounds(Width - ow - Tema.S(6), Tema.S(4), ow, Height - Tema.S(8));
        }
        protected override void OnResize(EventArgs e) { base.OnResize(e); Arrumar(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            var g = e.Graphics;
            Desenho.Preparar(g);
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (var p = Desenho.Arredondado(r, Tema.S(6)))
            using (var b = new SolidBrush(t.Campo))
            using (var pen = new Pen(foco ? t.Ouro : t.CampoBorda, Math.Max(1f, Tema.F)))
            {
                g.FillPath(b, p);
                g.DrawPath(pen, p);
            }
        }
    }

    // Lista suspensa desenhada no tema (abre um menu com as opções).
    public class Lista : Base
    {
        public List<string> Itens = new List<string>();
        int indice = -1;
        public event EventHandler Escolheu;
        public Lista() { Cursor = Cursors.Hand; }
        public int Indice { get { return indice; } set { indice = value; Text = (indice >= 0 && indice < Itens.Count) ? Itens[indice] : ""; Invalidate(); } }
        public string Escolhido { get { return (indice >= 0 && indice < Itens.Count) ? Itens[indice] : null; } }

        protected override void OnClick(EventArgs e)
        {
            base.OnClick(e);
            var m = new ContextMenuStrip();
            m.Renderer = new ToolStripProfessionalRenderer(new CoresMenu());
            m.ShowImageMargin = false;
            m.Font = new Font("Segoe UI", 10.5f);
            for (int i = 0; i < Itens.Count; i++)
            {
                int k = i;
                var it = new ToolStripMenuItem(Itens[i]);
                it.ForeColor = i == indice ? Tema.Atual.Ouro : Tema.Atual.Texto;
                it.AutoSize = false;
                it.Size = new Size(Width - 4, Tema.S(32));
                it.Click += delegate { Indice = k; if (Escolheu != null) Escolheu(this, EventArgs.Empty); };
                m.Items.Add(it);
            }
            m.Show(this, new Point(0, Height + Tema.S(2)));
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            var g = e.Graphics;
            Desenho.Preparar(g);
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (var p = Desenho.Arredondado(r, Tema.S(6)))
            using (var b = new SolidBrush(t.Campo))
            using (var pen = new Pen(t.CampoBorda, Math.Max(1f, Tema.F)))
            {
                g.FillPath(b, p);
                g.DrawPath(pen, p);
            }
            using (var f = new Font("Segoe UI", 11f))
                Desenho.Texto(g, Text, f, t.Texto, new Rectangle(Tema.S(14), 0, Width - Tema.S(48), Height), TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            using (var f = Desenho.Icones(10f))
                Desenho.Texto(g, "", f, t.Texto, new Rectangle(Width - Tema.S(36), 0, Tema.S(24), Height), TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
        }
    }

    public class CoresMenu : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground { get { return Tema.Atual.Campo; } }
        public override Color MenuBorder { get { return Tema.Atual.CampoBorda; } }
        public override Color MenuItemBorder { get { return Tema.Atual.Campo; } }
        public override Color MenuItemSelected { get { return Desenho.Misturar(Tema.Atual.Campo, Tema.Atual.Ouro, 0.18f); } }
        public override Color MenuItemSelectedGradientBegin { get { return MenuItemSelected; } }
        public override Color MenuItemSelectedGradientEnd { get { return MenuItemSelected; } }
        public override Color ImageMarginGradientBegin { get { return Tema.Atual.Campo; } }
        public override Color ImageMarginGradientMiddle { get { return Tema.Atual.Campo; } }
        public override Color ImageMarginGradientEnd { get { return Tema.Atual.Campo; } }
        public override Color SeparatorDark { get { return Tema.Atual.CampoBorda; } }
        public override Color SeparatorLight { get { return Tema.Atual.CampoBorda; } }
    }

    // Interruptor liga/desliga ("Iniciar com o Windows").
    public class Chave : Base
    {
        bool marcado;
        public event EventHandler Mudou;
        public Chave() { Cursor = Cursors.Hand; FundoNome = "fundo"; }
        public bool Marcado { get { return marcado; } set { marcado = value; Invalidate(); } }
        protected override void OnClick(EventArgs e)
        {
            base.OnClick(e);
            Marcado = !marcado;
            if (Mudou != null) Mudou(this, EventArgs.Empty);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            var g = e.Graphics;
            Desenho.Preparar(g);
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (var p = Desenho.Arredondado(r, (Height - 1) / 2f))
            using (var b = new SolidBrush(marcado ? t.Ouro : t.ChaveTrilho))
                g.FillPath(b, p);
            float d = Height - Tema.S(6);
            float x = marcado ? Width - d - Tema.S(3) : Tema.S(3);
            using (var b = new SolidBrush(marcado ? t.SobreOuro : t.ChaveBolinha))
                g.FillEllipse(b, x, Tema.S(3), d, d);
        }
    }

    // Linha divisória.
    public class Divisor : Base
    {
        protected override void OnPaint(PaintEventArgs e)
        {
            using (var p = new Pen(Tema.Atual.Borda, Math.Max(1f, Tema.F)))
            {
                if (Width >= Height) e.Graphics.DrawLine(p, 0, Height / 2, Width, Height / 2);
                else e.Graphics.DrawLine(p, Width / 2, 0, Width / 2, Height);
            }
        }
    }

    // Caixa do log (TextBox somente leitura, sem barra de rolagem clara, dentro de uma borda arredondada).
    public class CaixaLog : Base, ITematico
    {
        public TextBox Caixa = new TextBox();
        public CaixaLog()
        {
            Caixa.Multiline = true;
            Caixa.ReadOnly = true;
            Caixa.BorderStyle = BorderStyle.None;
            Caixa.ScrollBars = ScrollBars.Vertical;
            Caixa.WordWrap = true;
            Caixa.Font = new Font("Consolas", 10f);
            Caixa.HandleCreated += delegate { try { SetWindowTheme(Caixa.Handle, "DarkMode_Explorer", null); } catch { } };
            Controls.Add(Caixa);
            AplicarTema();
        }

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr h, string app, string lista);
        public static void TemaEscuro(IntPtr h) { SetWindowTheme(h, "DarkMode_Explorer", null); }
        public void AplicarTema() { Caixa.BackColor = Tema.Atual.Log; Caixa.ForeColor = Tema.Atual.Texto; }
        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            int p = Tema.S(12);
            Caixa.SetBounds(p, Tema.S(10), Width - 2 * p, Height - Tema.S(20));
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var t = Tema.Atual;
            var g = e.Graphics;
            Desenho.Preparar(g);
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (var p = Desenho.Arredondado(r, Tema.S(6)))
            using (var b = new SolidBrush(t.Log))
            using (var pen = new Pen(t.LogBorda, Math.Max(1f, Tema.F)))
            {
                g.FillPath(b, p);
                g.DrawPath(pen, p);
            }
        }
    }

}
'@
$CabecalhoDragao = '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'
$CabecalhoLago = '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'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Distro = 'LoRBots'
$Pasta = $PSScriptRoot
# main, ou a branch de teste com que o instalador rodou (ramo.txt)
$Ramo = 'main'
if ($env:LOR_RAMO) { $Ramo = $env:LOR_RAMO }
elseif (Test-Path (Join-Path $Pasta 'ramo.txt')) { $Ramo = (Get-Content (Join-Path $Pasta 'ramo.txt') -TotalCount 1).Trim() }
$Raw = "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$Ramo"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$ArquivoSkin = Join-Path $Pasta 'skin.txt'
$Lancador = Join-Path $Pasta 'Painel.vbs'
$AtalhoLigar = Join-Path ([Environment]::GetFolderPath('Startup')) 'LoR Bots (ligar).lnk'

function Rodar-Oculto([string]$comando) {
    # Sem janela nenhuma. Com o Windows Terminal como console padrão (Windows 11), o
    # "-WindowStyle Hidden" ainda abre uma janela do Terminal; o Run do WScript com estilo 0 não.
    [void](New-Object -ComObject WScript.Shell).Run($comando, 0, $false)
}

function Preparar-Atalhos {
    # O Painel.vbs abre este arquivo sem janela do PowerShell, e os atalhos (Área de Trabalho, menu
    # Iniciar, "Iniciar com o Windows") apontam para ele. Instalações antigas apontavam direto para o
    # powershell.exe e são consertadas aqui, na primeira vez que o painel novo abre.
    $vbs = @(
        "' Abre o Painel LoR Bots sem janela do PowerShell (gerado pelo Painel.ps1; os argumentos vão junto).",
        'Set sh = CreateObject("WScript.Shell")',
        'args = ""',
        'For Each a In WScript.Arguments : args = args & " " & a : Next',
        ('sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{0}""" & args, 0, False' -f (Join-Path $Pasta 'Painel.ps1'))
    )
    # UTF-16 com BOM: o WScript lê assim caminhos com acento (C:\Users\João\...).
    Set-Content -Path $Lancador -Value $vbs -Encoding Unicode
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sh = New-Object -ComObject WScript.Shell
    $alvos = @(
        @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Painel LoR Bots.lnk'), ''),
        @((Join-Path ([Environment]::GetFolderPath('Programs')) 'Painel LoR Bots.lnk'), ''),
        @($AtalhoLigar, ' -Ligar')
    )
    foreach ($a in $alvos) {
        if (-not (Test-Path $a[0])) { continue }
        $l = $sh.CreateShortcut($a[0])
        $argumentos = "`"$Lancador`"" + $a[1]
        if ($l.TargetPath -ne $wscript -or $l.Arguments -ne $argumentos) {
            $l.TargetPath = $wscript
            $l.Arguments = $argumentos
            $l.WorkingDirectory = $Pasta
            if ($l.IconLocation -match '^,|powershell') { $l.IconLocation = 'shell32.dll,137' }
            $l.Save()
        }
    }
}

function Invoke-Painel {
    # Roda painel.sh no Linux; o que é texto do usuário (senha, nomes, times) vai pela entrada
    # padrão, nunca na linha de comando.
    param([string[]]$Argumentos, [string]$Entrada = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = "-d $Distro -u root -e /opt/lor-bots/painel.sh " + ($Argumentos -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($Entrada) {
        $bytes = $Utf8.GetBytes($Entrada)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    }
    $p.StandardInput.Close()
    $saida = $p.StandardOutput.ReadToEnd()
    $erro = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Codigo = $p.ExitCode; Saida = $saida.Trim(); Erro = $erro.Trim() }
}

function Ler-Estado {
    $r = Invoke-Painel @('estado')
    $e = @{}
    foreach ($linha in $r.Saida -split "`n") {
        $i = $linha.IndexOf('=')
        if ($i -gt 0) { $e[$linha.Substring(0, $i)] = $linha.Substring($i + 1).Trim() }
    }
    $e
}

function Manter-Vivo {
    # O WSL desliga o Linux quando nenhum programa do Windows o usa; este processo escondido
    # segura enquanto o bot estiver ligado (e sai sozinho depois).
    Rodar-Oculto "wsl.exe -d $Distro -u root -e /opt/lor-bots/painel.sh manter-vivo"
}

function Mensagem([string]$texto, [string]$titulo = 'Painel LoR Bots') {
    [System.Windows.Forms.MessageBox]::Show($texto, $titulo) | Out-Null
}

if ($Ligar) {
    $r = Invoke-Painel @('ligar')
    if ($r.Codigo -eq 0) { Manter-Vivo }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Um painel só: abrir de novo pelo atalho não cria uma segunda janela.
$criado = $false
$trava = New-Object System.Threading.Mutex($true, 'Local\LoRBotsPainel', [ref]$criado)
if (-not $criado) {
    [System.Windows.Forms.MessageBox]::Show('O Painel LoR Bots já está aberto.', 'Painel LoR Bots') | Out-Null
    return
}
try { Preparar-Atalhos } catch { }

# Nítido em telas com escala (125%, 150%...): o painel cuida do DPI e multiplica as posições.
Add-Type -Name Dpi -Namespace LoRNativo -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][LoRNativo.Dpi]::SetProcessDPIAware()
Add-Type -TypeDefinition $CodigoUI -ReferencedAssemblies System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
[LoR.Tema]::F = $g0.DpiX / 96
$g0.Dispose()

function S([double]$v) { [LoR.Tema]::S($v) }
function Cor([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Imagem([string]$b64) { [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, [Convert]::FromBase64String($b64)))) }

function Novo-Tema($id, $nome, $cores, $extra) {
    $t = New-Object LoR.Tema
    $t.Id = $id
    $t.Nome = $nome
    foreach ($k in $cores.Keys) { $t.$k = Cor $cores[$k] }
    foreach ($k in $extra.Keys) { $t.$k = $extra[$k] }
    $t
}

# Paletas tiradas dos modelos (windows/skins/NOTAS.md).
$Temas = [ordered]@{
    dragao = Novo-Tema 'dragao' 'Dragão (vermelho e dourado)' @{
        Fundo = '#0F1215'; Moldura = '#8E1016'; Cartao = '#161A1D'; Borda = '#4A3B1C'; Texto = '#F1F1EF'
        Suave = '#A7ADB2'; Sub = '#A7ADB2'; Ouro = '#E8BB52'; SobreOuro = '#15120A'; TextoContorno = '#F1F1EF'
        Campo = '#1B2023'; CampoBorda = '#545C63'; Neutro = '#4B5157'; Desligado = '#2C3136'; DesligadoTexto = '#7C838A'
        Vermelho = '#E5484D'; Verde = '#56C377'; PontoVerde = '#56C377'; VerdeFundo = '#18301F'; VerdeBorda = '#2F6B44'
        VerdeTexto = '#74D693'; Pilula = '#23282C'; PilulaBorda = '#383F45'; Log = '#0D1012'; LogBorda = '#2A3035'
        Ambar = '#F49E2A'; ChaveTrilho = '#3A4045'; ChaveBolinha = '#D9D9D4'; SimboloJanela = '#1C1405'
        Escama = '#000000'; LinhaCabecalho = '#000000'
    } @{ LarguraMoldura = [single]2; LegendaAoLado = $true; ImagemCabecalho = (Imagem $CabecalhoDragao) }
    lago = Novo-Tema 'lago' 'Lago (azul e dourado)' @{
        Fundo = '#021631'; Moldura = '#0A1F44'; Cartao = '#061B38'; Borda = '#12325E'; Texto = '#EEF2F8'
        Suave = '#9FB0C8'; Sub = '#7FA0D0'; Ouro = '#DDB65E'; SobreOuro = '#10131A'; TextoContorno = '#E8C46E'
        Campo = '#081A31'; CampoBorda = '#24416A'; Neutro = '#2D4D7C'; Desligado = '#1A2C45'; DesligadoTexto = '#6E83A0'
        Vermelho = '#EE5A52'; Verde = '#4CBA71'; PontoVerde = '#4CBA71'; VerdeFundo = '#1E6B42'; VerdeBorda = '#1E6B42'
        VerdeTexto = '#EAFBF0'; Pilula = '#13284A'; PilulaBorda = '#24406A'; Log = '#071426'; LogBorda = '#16305A'
        Ambar = '#F2A33A'; ChaveTrilho = '#22385A'; ChaveBolinha = '#9AA9C2'; SimboloJanela = '#E6EAF2'
        Escama = '#000000'; LinhaCabecalho = '#000000'
    } @{ LarguraMoldura = [single]1; LegendaAoLado = $false; ImagemCabecalho = (Imagem $CabecalhoLago) }
}
$skin = 'dragao'
try { $s = (Get-Content $ArquivoSkin -TotalCount 1).Trim(); if ($Temas.Contains($s)) { $skin = $s } } catch { }
[LoR.Tema]::Atual = $Temas[$skin]

# ---------------------------------------------------------------------------------------------
# Janela

$form = New-Object LoR.Janela
$form.Text = 'Painel LoR Bots'
$form.AutoScaleMode = 'None'
$form.StartPosition = 'CenterScreen'
$form.AlturaCabecalho = S 60
$form.ClientSize = New-Object System.Drawing.Size((S 1024), (S 694))
$form.BackColor = [LoR.Tema]::Atual.Fundo
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\shell32.dll") } catch { }

function Pos($c, $x, $y, $w, $h, $pai) {
    $c.SetBounds((S $x), (S $y), (S $w), (S $h))
    $pai.Controls.Add($c)
    $c
}
function Novo-Cartao($titulo, $legenda, $x, $y, $w, $h) {
    $c = New-Object LoR.Cartao
    $c.Titulo = $titulo
    $c.Subtitulo = $legenda
    Pos $c $x $y $w $h $form
}
function Novo-Botao($texto, $estilo, $icone, $x, $y, $w, $h, $pai) {
    $b = New-Object LoR.Botao
    $b.Text = $texto
    $b.Estilo = [LoR.Estilo]::$estilo
    $b.Icone = $icone
    Pos $b $x $y $w $h $pai
}
function Novo-Rotulo($texto, $x, $y, $w, $h, $pai, $cor = 'texto', $tamanho = 10, $negrito = $false) {
    $r = New-Object LoR.Rotulo
    $r.Text = $texto
    $r.CorNome = $cor
    $r.Tamanho = $tamanho
    $r.Negrito = $negrito
    Pos $r $x $y $w $h $pai
}
function Novo-Campo($dica, $x, $y, $w, $h, $pai) {
    $c = New-Object LoR.Campo
    Pos $c $x $y $w $h $pai | Out-Null
    $c.AplicarTema()
    $c.Dica = $dica
    $c
}
function Nova-Lista($itens, $x, $y, $w, $h, $pai) {
    $l = New-Object LoR.Lista
    foreach ($i in $itens) { $l.Itens.Add($i) }
    $l.Indice = 0
    Pos $l $x $y $w $h $pai
}

# Botões do cabeçalho: tema, minimizar, fechar.
function Novo-BotaoJanela($simbolo, $x) {
    $b = New-Object LoR.BotaoJanela
    $b.Simbolo = $simbolo
    $b.SetBounds((S $x), (S 10), (S 46), (S 40))
    $form.Controls.Add($b)
    $b
}
$bTema = Novo-BotaoJanela ([string][char]0xE790) 830
$bMin = Novo-BotaoJanela ([string][char]0xE921) 876
$bFechar = Novo-BotaoJanela ([string][char]0xE8BB) 922
$bFechar.Fechar = $true
$bMin.Add_Click({ $form.WindowState = 'Minimized' })
$bFechar.Add_Click({ $form.Close() })
$ttTema = New-Object System.Windows.Forms.ToolTip
$ttTema.SetToolTip($bTema, 'Aparência do painel')

# Status
$cStatus = Novo-Cartao '' '' 13 69 998 132
$pBot = New-Object LoR.Bolinha
[void](Pos $pBot 22 22 22 22 $cStatus)
$lBot = Novo-Rotulo 'Carregando…' 56 12 400 36 $cStatus 'texto' 15 $true
$selo = New-Object LoR.Pilula
[void](Pos $selo 300 17 200 27 $cStatus)
$selo.Visible = $false
$chip = New-Object LoR.Pilula
$chip.Tipo = 'neutra'
$chip.Simbolo = [string][char]0xE950
[void](Pos $chip 520 17 110 27 $cStatus)
$chip.Visible = $false
$lInfo = Novo-Rotulo 'ligando o Linux dos bots' 56 47 540 24 $cStatus 'suave' 11
$bVer = Novo-Botao 'Ver ao vivo' 'Neutro' ([string][char]0xE8A7) 22 82 140 38 $cStatus
$bHistorico = Novo-Botao 'Histórico de partidas' 'Neutro' ([string][char]0xE8FD) 174 82 210 38 $cStatus
$div = New-Object LoR.Divisor
[void](Pos $div 604 18 4 96 $cStatus)
$bLigar = Novo-Botao 'Iniciar' 'Primario' ([string][char]0x25B6) 632 20 140 40 $cStatus
$bDesligar = Novo-Botao 'Parar após a partida' 'Primario' ([string][char]0x25A0) 784 20 196 40 $cStatus
$bAgora = Novo-Botao 'Parar agora' 'Perigo' ([string][char]0xE7BA) 706 70 200 36 $cStatus
$lAgora = Novo-Rotulo 'Interrompe a partida atual' 676 108 260 20 $cStatus 'suave' 9.5
$lAgora.Alinhar = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter'

# Configuração de partidas
$cJogo = Novo-Cartao 'Configuração de partidas' 'Ladder oficial · Reg M-C' 13 211 595 164
[void](Novo-Rotulo 'Formato' 20 50 200 20 $cJogo)
[void](Novo-Rotulo 'Time' 261 50 200 20 $cJogo)
$cFormato = Nova-Lista @('BO3', 'BO1') 20 72 224 36 $cJogo
$cTime = Nova-Lista @('Top 3 (padrão)') 261 72 206 36 $cJogo
$bAplicar = Novo-Botao 'Aplicar' 'Contorno' '' 480 72 96 36 $cJogo
$sep = New-Object LoR.Divisor
[void](Pos $sep 20 114 555 4 $cJogo)
$bAddTime = Novo-Botao 'Adicionar time' 'Contorno' ([string][char]0xE710) 20 124 150 32 $cJogo
$bRemTime = Novo-Botao 'Remover time' 'Neutro' ([string][char]0xE74D) 182 124 150 32 $cJogo

# Coleta
$cColeta = Novo-Cartao 'Coleta de times' 'Código para treino e Discord' 13 385 595 112
$tCodigo = Novo-Campo 'Cole seu código' 20 50 440 36 $cColeta
$tCodigo.Caixa.UseSystemPasswordChar = $true
$bCodigo = Novo-Botao 'Salvar código' 'Contorno' '' 472 50 106 36 $cColeta
$pCodigo = New-Object LoR.Bolinha
$pCodigo.Brilho = $false
$pCodigo.CorNome = 'ambar'
[void](Pos $pCodigo 22 94 10 10 $cColeta)
$lCodigo = Novo-Rotulo 'Não salvo' 38 88 540 22 $cColeta 'ambar' 10

# Conta do Showdown
$cConta = Novo-Cartao 'Conta do Showdown' '' 618 211 393 286
[void](Novo-Rotulo 'Usuário' 20 50 200 20 $cConta)
$tUsuario = Novo-Campo '' 20 72 353 38 $cConta
[void](Novo-Rotulo 'Senha' 20 120 200 20 $cConta)
$tSenha = Novo-Campo '' 20 142 353 38 $cConta
$tSenha.ComOlho()
$iCadeado = New-Object LoR.Icone
$iCadeado.Text = [string][char]0xE72E
[void](Pos $iCadeado 20 190 20 22 $cConta)
[void](Novo-Rotulo 'A senha fica apenas neste PC.' 46 190 320 22 $cConta 'suave' 10)
$bConta = Novo-Botao 'Salvar conta' 'Contorno' '' 222 228 151 38 $cConta

# Atividade
$cLog = Novo-Cartao 'Atividade' '' 13 507 998 133
$cFiltro = Nova-Lista @('Todos', 'Partidas', 'Avisos') 750 10 124 32 $cLog
$bRecolher = Novo-Botao 'Recolher' 'Fantasma' ([string][char]0xE70E) 880 10 104 32 $cLog
$tLog = New-Object LoR.CaixaLog
[void](Pos $tLog 16 50 966 72 $cLog)

# Rodapé
$xAuto = New-Object LoR.Chave
[void](Pos $xAuto 24 656 40 22 $form)
$lAuto = Novo-Rotulo 'Iniciar com o Windows' 74 652 300 30 $form 'texto' 10
$lAuto.FundoNome = 'fundo'
$lAuto.Cursor = 'Hand'
$lAtualizar = Novo-Rotulo 'Verificar atualização' 830 652 170 30 $form 'ouro' 10
$lAtualizar.FundoNome = 'fundo'
$lAtualizar.Sublinhado = $true
$lAtualizar.Cursor = 'Hand'
$lAtualizar.Alinhar = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter'
$lVersao = Novo-Rotulo 'Versão' 560 652 254 30 $form 'suave' 10
$lVersao.FundoNome = 'fundo'
$lVersao.Alinhar = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter'
$divRodape = New-Object LoR.Divisor
$divRodape.FundoNome = 'fundo'
[void](Pos $divRodape 818 656 4 22 $form)

$Atalho = $AtalhoLigar
$xAuto.Marcado = Test-Path $Atalho

# Menu de aparência.
function Escolher-Tema($id) {
    [LoR.Tema]::Atual = $Temas[$id]
    try { Set-Content -Path $ArquivoSkin -Value $id -Encoding ASCII } catch { }
    $form.AplicarTema()
    Arrumar-Status
}
$bTema.Add_Click({
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $m.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object LoR.CoresMenu))
    $m.ShowImageMargin = $false
    $m.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
    foreach ($id in $Temas.Keys) {
        $atual = [LoR.Tema]::Atual.Id -eq $id
        $it = New-Object System.Windows.Forms.ToolStripMenuItem((@('    ', '✓ ')[[int]$atual]) + $Temas[$id].Nome)
        $it.ForeColor = if ($atual) { [LoR.Tema]::Atual.Ouro } else { [LoR.Tema]::Atual.Texto }
        $it.Tag = $id
        $it.Add_Click({ param($s) Escolher-Tema $s.Tag })
        [void]$m.Items.Add($it)
    }
    $m.Show($bTema, (New-Object System.Drawing.Point(((S 46) - (S 250)), $bTema.Height)))
})

# ---------------------------------------------------------------------------------------------
# Estado

$script:estado = @{}
$script:versaoNova = $null
$script:recolhido = $false

# Frases curtas no lugar das linhas cruas do bot (o que não reconhece aparece como veio).
function Traduzir-Log([string[]]$linhas, [string]$filtro) {
    $saida = New-Object System.Collections.Generic.List[string]
    foreach ($l in $linhas) {
        $l = $l.TrimEnd()
        if (-not $l) { continue }
        $tipo = 'outro'
        $txt = $null
        if ($l -match '^Started lor-bot@') { $txt = 'Bot iniciado' }
        elseif ($l -match "^'(.+)' laddering (\S+) at ([^:]+):") { $txt = "Conta $($Matches[1]) conectada · procurando partida no ladder" }
        elseif ($l -match '^team: (\S+)') { $txt = "Time da vez: $($Matches[1])" }
        elseif ($l -match '^watch: (\S+)') { $txt = "Partida em andamento · $($Matches[1])"; $tipo = 'partida' }
        elseif ($l -match '^(win|loss|tie) vs (.+) in (\d+) turns') {
            $r = @{ win = 'Vitória'; loss = 'Derrota'; tie = 'Empate' }[$Matches[1]]
            $txt = "$r contra $($Matches[2]) em $($Matches[3]) turnos"; $tipo = 'partida'
        }
        elseif ($l -match '^(\d+)/(\d+) games won by') { $txt = "Placar desde que ligou: $($Matches[1]) de $($Matches[2]) jogos ganhos"; $tipo = 'partida' }
        elseif ($l -match '^Ctrl-C: finishing') { $txt = 'Parando depois da partida (ou série) atual' }
        elseif ($l -match '^Stopping lor-bot@') { $txt = 'Desligando…' }
        elseif ($l -match '^Stopped lor-bot@') { $txt = 'Bot parado' }
        elseif ($l -match '^\s+search:|Deactivated successfully|Killing process|remains running|^lor-bot@.*Consumed|SyntaxWarning|^\s+function showErr') { continue }
        elseif ($l -match 'Received pm: \|pm\|\s*([^|]+)\|') {
            # Mensagens privadas no Showdown: só uma linha por pedido de amizade, o resto do HTML some.
            $de = $Matches[1].Trim()
            if ($l -match 'sent you a friend request') { $txt = "Pedido de amizade de $de no Showdown" }
            elseif ($l -match '/uhtml|/raw') { continue }
            else { $txt = "Mensagem de $de no Showdown" }
        }
        elseif ($l -match 'Traceback|Error|ERROR|WARNING|Unhandled|failed|Failed') { $txt = "⚠ $l"; $tipo = 'aviso' }
        else { $txt = $l }
        if ($filtro -eq 'Partidas' -and $tipo -ne 'partida') { continue }
        if ($filtro -eq 'Avisos' -and $tipo -ne 'aviso') { continue }
        $saida.Add($txt)
    }
    $saida
}

function Arrumar-Status {
    # O selo e o chip de memória vêm logo depois do título, que muda de largura.
    $lBot.Width = $lBot.LarguraTexto() + (S 8)
    $x = $lBot.Right + (S 12)
    if ($selo.Visible) { $selo.SetBounds($x, (S 17), $selo.LarguraIdeal(), (S 27)); $x = $selo.Right + (S 12) }
    if ($chip.Visible) { $chip.SetBounds($x, (S 17), $chip.LarguraIdeal(), (S 27)) }
}

function Atualizar-Tela {
    $e = Ler-Estado
    $script:estado = $e
    $bot = $e['bot']
    $ligado = $bot -in @('active', 'activating')
    $titulos = @{ active = 'Bot em execução'; activating = 'Ligando…'; deactivating = 'Parando após a partida'
        inactive = 'Bot parado'; failed = 'Bot parou com erro' }
    $lBot.Text = if ($titulos[$bot]) { $titulos[$bot] } else { "Bot: $bot" }
    $pBot.CorNome = switch ($bot) { 'active' { 'ponto' } 'failed' { 'vermelho' } { $_ -in 'activating', 'deactivating' } { 'ambar' } default { 'desligado' } }
    $pBot.Invalidate()
    if ($e['partida']) { $selo.Tipo = 'verde'; $selo.Text = 'Partida em andamento'; $selo.Visible = $true }
    elseif ($bot -eq 'active') { $selo.Tipo = 'neutra'; $selo.Text = 'Procurando partida'; $selo.Visible = $true }
    elseif ($bot -eq 'failed') { $selo.Tipo = 'ambar'; $selo.Text = 'Veja a atividade'; $selo.Visible = $true }
    else { $selo.Visible = $false }
    $chip.Visible = [bool]$e['memoria_mb']
    $chip.Text = "$($e['memoria_mb']) MB"
    Arrumar-Status
    $conta = if ($e['conta']) { $e['conta'] } else { 'sem conta' }
    $time = if ($e['time'] -eq 'top3' -or -not $e['time']) { 'Top 3' } else { $e['time'] }
    $lInfo.Text = "$conta  ·  $(([string]$e['formato']).ToUpper())  ·  $time"
    $lVersao.Text = "Versão $($e['versao'])"
    if ($script:versaoNova -and $script:versaoNova -ne $e['versao']) {
        $lAtualizar.Text = "Atualizar para $($script:versaoNova)"
        $lAtualizar.Negrito = $true
    } else {
        $lAtualizar.Text = 'Verificar atualização'
        $lAtualizar.Negrito = $false
    }
    if (-not $tUsuario.Caixa.Focused -and -not $tUsuario.Caixa.Modified) { $tUsuario.Caixa.Text = $e['conta'] }
    $tSenha.Dica = if ($e['senha'] -eq 'sim') { 'Senha salva (digite para trocar)' } else { 'Senha da conta' }
    if ($e['codigo'] -eq 'sim') {
        $tCodigo.Dica = 'Código salvo (cole outro para trocar)'
        $pCodigo.CorNome = 'ponto'
        $lCodigo.CorNome = 'verde'
        $lCodigo.Text = if ($e['envio'] -eq 'active') { 'Salvo · enviando as partidas' } else { 'Salvo · o envio liga junto com o bot' }
    } else {
        $tCodigo.Dica = 'Cole seu código'
        $pCodigo.CorNome = 'ambar'
        $lCodigo.CorNome = 'ambar'
        $lCodigo.Text = 'Não salvo'
    }
    $pCodigo.Invalidate()
    if (-not $script:recolhido) {
        $linhas = (Invoke-Painel @('log', '80')).Saida -split "`n"
        $texto = (Traduzir-Log $linhas $cFiltro.Escolhido | Select-Object -Last 40) -join "`r`n"
        if ($tLog.Caixa.Text -ne $texto) {
            $tLog.Caixa.Text = $texto
            $tLog.Caixa.SelectionStart = $tLog.Caixa.Text.Length
            $tLog.Caixa.ScrollToCaret()
        }
    }
    $bLigar.Enabled = -not $ligado -and $bot -ne 'deactivating'
    $bDesligar.Enabled = $ligado
    $bAgora.Enabled = $bot -in @('active', 'activating', 'deactivating')
    $bVer.Enabled = [bool]$e['partida']
}

function Carregar-Opcoes {
    $e = Ler-Estado
    $cFormato.Indice = if ($e['formato'] -eq 'bo1') { 1 } else { 0 }
    $cTime.Itens.Clear()
    $cTime.Itens.Add('Top 3 (padrão)')
    foreach ($t in ((Invoke-Painel @('times')).Saida -split "`n")) { if ($t.Trim()) { $cTime.Itens.Add($t.Trim()) } }
    $i = if ($e['time'] -and $e['time'] -ne 'top3') { $cTime.Itens.IndexOf($e['time']) } else { 0 }
    $cTime.Indice = [Math]::Max(0, $i)
}

function Resultado($r, [string]$ok) {
    if ($r.Codigo -eq 0) { if ($ok) { Mensagem $ok }; return $true }
    $msg = (($r.Saida + "`n" + $r.Erro).Trim() -replace '^erro=', '')
    Mensagem "Não deu certo:`n`n$msg"
    $false
}

# ---------------------------------------------------------------------------------------------
# Ações

$bConta.Add_Click({
    if (-not $tUsuario.Caixa.Text.Trim()) { Mensagem 'Coloque o usuário do Showdown.'; return }
    if (-not $tSenha.Caixa.Text -and $script:estado['senha'] -ne 'sim') { Mensagem 'Coloque a senha da conta.'; return }
    $r = Invoke-Painel @('conta') ("$($tUsuario.Caixa.Text.Trim())`n$($tSenha.Caixa.Text)`n")
    $tSenha.Caixa.Text = ''
    $tUsuario.Caixa.Modified = $false
    if (Resultado $r '') {
        if ($script:estado['bot'] -eq 'active') {
            Invoke-Painel @('reiniciar') | Out-Null
            Mensagem 'Conta salva. O bot entra com ela depois da partida atual.'
        } else { Mensagem 'Conta salva.' }
    }
    Atualizar-Tela
})

$bCodigo.Add_Click({
    if (-not $tCodigo.Caixa.Text.Trim()) { Mensagem 'Cole o código que o Thiago passou.'; return }
    $r = Invoke-Painel @('codigo') ($tCodigo.Caixa.Text.Trim() + "`n")
    if (Resultado $r 'Código salvo. As partidas deste bot vão para a coleta do time.') { $tCodigo.Caixa.Text = '' }
    Atualizar-Tela
})

$bAplicar.Add_Click({
    $f = if ($cFormato.Indice -eq 1) { 'bo1' } else { 'bo3' }
    $t = if ($cTime.Indice -le 0) { 'top3' } else { $cTime.Escolhido }
    if (-not (Resultado (Invoke-Painel @('formato', $f)) '')) { return }
    if (-not (Resultado (Invoke-Painel @('time', $t)) '')) { return }
    $r = Invoke-Painel @('reiniciar')
    if ($r.Saida -match 'reiniciando') { Mensagem 'Salvo. O bot reinicia com isso depois da partida (ou série) atual.' }
    else { Mensagem 'Salvo. Vale na próxima vez que ligar.' }
    Atualizar-Tela
})

$bAddTime.Add_Click({
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Adicionar time'
    $d.AutoScaleMode = 'None'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ClientSize = New-Object System.Drawing.Size((S 480), (S 440))
    $d.StartPosition = 'CenterParent'
    $d.BackColor = [LoR.Tema]::Atual.Fundo
    $d.Font = $form.Font
    [LoR.Janela]::TituloEscuro($d)
    $r1 = Novo-Rotulo 'Nome (letras, números, - e _)' 20 16 440 22 $d
    $r1.FundoNome = 'fundo'
    $tNome = Novo-Campo 'ex.: meu-time' 20 42 240 36 $d
    $tNome.FundoNome = 'fundo'
    $r2 = Novo-Rotulo 'Link do pokepast.es ou o export do Showdown' 20 92 440 22 $d
    $r2.FundoNome = 'fundo'
    $tTexto = Novo-Campo '' 20 118 440 250 $d
    $tTexto.FundoNome = 'fundo'
    $tTexto.Multilinha()
    $bOk = Novo-Botao 'Salvar' 'Primario' '' 252 384 100 38 $d
    $bOk.FundoNome = 'fundo'
    $bCancelar = Novo-Botao 'Cancelar' 'Neutro' '' 360 384 100 38 $d
    $bCancelar.FundoNome = 'fundo'
    $bCancelar.Add_Click({ $d.Close() })
    $bOk.Add_Click({
        $d.Cursor = 'WaitCursor'
        $r = Invoke-Painel @('adicionar-time') ($tNome.Caixa.Text.Trim() + "`n" + $tTexto.Caixa.Text)
        $d.Cursor = 'Default'
        if (Resultado $r 'Time válido e salvo. Escolha ele na lista e clique em Aplicar.') { $d.Close() }
    })
    [void]$d.ShowDialog($form)
    Carregar-Opcoes
})

$bRemTime.Add_Click({
    if ($cTime.Indice -le 0) { Mensagem 'Escolha na lista um time que você adicionou.'; return }
    $t = $cTime.Escolhido
    if ([System.Windows.Forms.MessageBox]::Show("Remover o time $t?", 'Painel LoR Bots', 'YesNo') -ne 'Yes') { return }
    [void](Resultado (Invoke-Painel @('remover-time', $t)) '')
    Carregar-Opcoes
    Atualizar-Tela
})

$bLigar.Add_Click({
    if (Resultado (Invoke-Painel @('ligar')) '') { Manter-Vivo }
    Atualizar-Tela
})
$bDesligar.Add_Click({ [void](Resultado (Invoke-Painel @('desligar')) ''); Atualizar-Tela })
$bAgora.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('Parar agora? A partida em andamento fica pela metade (o bot perde por W.O.).',
        'Painel LoR Bots', 'YesNo') -ne 'Yes') { return }
    [void](Resultado (Invoke-Painel @('agora')) '')
    Atualizar-Tela
})
$bVer.Add_Click({
    # Abre no navegador a batalha em andamento.
    Atualizar-Tela
    if ($script:estado['partida']) { Start-Process $script:estado['partida'] }
    elseif ($script:estado['bot'] -in @('active', 'activating')) { Mensagem 'Nenhuma partida agora: o bot está procurando adversário. Tente de novo em instantes.' }
    else { Mensagem 'O bot está desligado.' }
})
$bHistorico.Add_Click({
    # Os replays que o bot salvou no Showdown; sem conta, a pasta das partidas neste PC.
    $conta = $script:estado['conta']
    if ($conta) { Start-Process ('https://replay.pokemonshowdown.com/?user=' + [Uri]::EscapeDataString($conta)) }
    else { Start-Process explorer.exe "\\wsl$\$Distro\opt\lor-bots\ai-vgc\data\live_games" }
})

$cFiltro.add_Escolheu({ $tLog.Caixa.Text = ''; Atualizar-Tela })
$bRecolher.Add_Click({
    $script:recolhido = -not $script:recolhido
    $dy = S 86
    if ($script:recolhido) {
        $tLog.Visible = $false
        $cLog.Height -= $dy
        $bRecolher.Text = 'Expandir'; $bRecolher.Icone = [string][char]0xE70D
        foreach ($c in @($xAuto, $lAuto, $lVersao, $lAtualizar, $divRodape)) { $c.Top -= $dy }
        $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - $dy))
    } else {
        $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height + $dy))
        foreach ($c in @($xAuto, $lAuto, $lVersao, $lAtualizar, $divRodape)) { $c.Top += $dy }
        $cLog.Height += $dy
        $tLog.Visible = $true
        $bRecolher.Text = 'Recolher'; $bRecolher.Icone = [string][char]0xE70E
        Atualizar-Tela
    }
    $form.Invalidate()
})

function Mudar-Auto {
    if ($xAuto.Marcado) {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($Atalho)
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $s.Arguments = "`"$Lancador`" -Ligar"
        $s.WorkingDirectory = $Pasta
        $s.IconLocation = 'shell32.dll,137'
        $s.Save()
    } elseif (Test-Path $Atalho) { Remove-Item $Atalho }
}
$xAuto.add_Mudou({ Mudar-Auto })
$lAuto.Add_Click({ $xAuto.Marcado = -not $xAuto.Marcado; Mudar-Auto })

function Atualizar-Painel {
    if ([System.Windows.Forms.MessageBox]::Show(
        "Baixar a versão $($script:versaoNova) do bot e do painel? Se o bot estiver jogando, ele termina a partida atual antes de reiniciar.",
        'Painel LoR Bots', 'YesNo') -ne 'Yes') { return }
    # O painel novo só entra no lugar deste depois que a atualização do Linux deu certo; antes disso
    # fica ao lado (Painel.novo.ps1), e o atual vira Painel.anterior.ps1 (para voltar à mão, se precisar).
    $atual = Join-Path $Pasta 'Painel.ps1'
    $novo = Join-Path $Pasta 'Painel.novo.ps1'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$Raw/windows/Painel.ps1" -OutFile $novo
        $erros = $null
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content $novo -Raw -Encoding UTF8), [ref]$erros)
        if ($erros.Count -gt 0) { throw 'o painel baixado veio incompleto ou com erro. Tente de novo.' }
    } catch {
        Remove-Item $novo -ErrorAction SilentlyContinue
        Mensagem "Não consegui baixar a versão nova: $($_.Exception.Message)"
        return
    }
    # O Linux numa janela que mostra o progresso; o código de saída diz se deu certo.
    $p = Start-Process wsl.exe -PassThru -ArgumentList "-d $Distro -u root -e env LOR_RAMO=$Ramo /opt/lor-bots/painel.sh atualizar"
    [void]$p.Handle  # guarda o processo, senão o ExitCode volta vazio
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        Remove-Item $novo -ErrorAction SilentlyContinue
        Mensagem ("A atualização do bot parou no meio (código $($p.ExitCode)). O painel continua nesta versão, e o bot " +
            "segue como estava. Tente Atualizar de novo; se falhar outra vez, mande um print da janela de progresso.")
        Manter-Vivo
        Atualizar-Tela
        return
    }
    try {
        Copy-Item -Force $atual (Join-Path $Pasta 'Painel.anterior.ps1')
        Move-Item -Force $novo $atual
    } catch {
        Mensagem "O bot foi atualizado, mas não consegui trocar o painel: $($_.Exception.Message)"
        return
    }
    Manter-Vivo
    $trava.ReleaseMutex()
    Start-Process wscript.exe -ArgumentList "`"$Lancador`""
    $form.Close()
}
$lAtualizar.Add_Click({
    try { $script:versaoNova = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri "$Raw/VERSION").Content.Trim() } catch { }
    if ($script:versaoNova -and $script:versaoNova -ne $script:estado['versao']) { Atualizar-Painel }
    elseif ($script:versaoNova) { Mensagem "Já está na versão mais nova ($($script:versaoNova))." }
    else { Mensagem 'Não consegui ver a versão no GitHub. Confira a internet e tente de novo.' }
    Atualizar-Tela
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    try { Atualizar-Tela } catch { $lBot.Text = 'Sem resposta do WSL'; $lInfo.Text = $_.Exception.Message; $pBot.CorNome = 'vermelho'; Arrumar-Status }
})

$form.Add_Shown({
    $form.Cursor = 'WaitCursor'
    # A primeira chamada liga o Linux do WSL e leva alguns segundos.
    $pBot.CorNome = 'ambar'
    $form.Refresh()
    try {
        Carregar-Opcoes
        if ($script:estado['bot'] -in @('active', 'activating', 'deactivating')) { Manter-Vivo }
        # Versão nova no GitHub? (só avisa; atualizar é no link do rodapé)
        try { $script:versaoNova = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri "$Raw/VERSION").Content.Trim() } catch { }
        Atualizar-Tela
    } catch {
        $lBot.Text = 'Sem resposta do WSL'
        $lInfo.Text = $_.Exception.Message
        $pBot.CorNome = 'vermelho'
        Arrumar-Status
    }
    $form.Cursor = 'Default'
    $timer.Start()
})

[void]$form.ShowDialog()
$timer.Stop()
try { $trava.ReleaseMutex() } catch { }
