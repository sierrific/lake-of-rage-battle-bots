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
            TabStop = false;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        }
        protected Color CorFundo { get { return Tema.Atual.Cor(FundoNome); } }
        protected override bool IsInputKey(Keys keyData)
        {
            var key = keyData & Keys.KeyCode;
            return (TabStop && (key == Keys.Enter || key == Keys.Space || key == Keys.Up || key == Keys.Down)) || base.IsInputKey(keyData);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(CorFundo); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
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
            TabStop = true;
            AccessibleRole = AccessibleRole.PushButton;
        }
        protected override bool IsInputKey(Keys keyData)
        {
            var key = keyData & Keys.KeyCode;
            return key == Keys.Enter || key == Keys.Space || base.IsInputKey(keyData);
        }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) { OnClick(EventArgs.Empty); e.Handled = e.SuppressKeyPress = true; }
            base.OnKeyDown(e);
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
        public bool Destaque;
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
            if (Destaque)
                using (var p = new Pen(t.Ouro, Math.Max(1f, Tema.F * 2f)))
                    g.DrawLine(p, Tema.S(12), Tema.S(1), Width - Tema.S(12), Tema.S(1));
            if (Titulo.Length > 0)
            {
                // Tema "lado": legenda à direita do título; senão, embaixo dele (e o título sobe um pouco).
                bool lado = Subtitulo.Length == 0;
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

    public enum Estilo { Primario, Contorno, Neutro, Perigo, Fantasma, Navegacao }

    public class Botao : Base
    {
        public Estilo Estilo = Estilo.Contorno;
        public string Icone = "";
        public bool Negrito = true;
        public bool Selecionado, SemBorda;
        bool sobre, apertado;
        public Botao() { Cursor = Cursors.Hand; TabStop = true; AccessibleRole = AccessibleRole.PushButton; }
        public void PerformClick() { if (Enabled) OnClick(EventArgs.Empty); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) { PerformClick(); e.Handled = e.SuppressKeyPress = true; }
            base.OnKeyDown(e);
        }
        protected override void OnMouseEnter(EventArgs e) { sobre = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { sobre = false; apertado = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { apertado = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { apertado = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { AccessibleName = Text; Invalidate(); base.OnTextChanged(e); }

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
                    case Estilo.Navegacao:
                        fundo = Selecionado ? t.Cartao : CorFundo;
                        borda = Selecionado ? t.Borda : CorFundo;
                        texto = Selecionado ? t.Ouro : t.Suave; break;
                    default: fundo = CorFundo; borda = t.Ouro; texto = t.TextoContorno; break;
                }
                if (sobre)
                {
                    fundo = Estilo == Estilo.Primario ? Desenho.Misturar(fundo, Color.White, apertado ? 0.05f : 0.18f)
                        : Desenho.Misturar(fundo, borda, apertado ? 0.22f : 0.12f);
                }
            }
            if (SemBorda) borda = fundo;
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
                int x = Estilo == Estilo.Navegacao ? Tema.S(12) : Math.Max(Tema.S(6), (Width - tam.Width - iw) / 2);
                if (iw > 0)
                {
                    Color ci = texto;
                    if (Estilo == Estilo.Perigo && Enabled) ci = t.Vermelho;
                    Desenho.Texto(g, Icone, fi, ci, new Rectangle(x, 0, Tema.S(18), Height), TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
                }
                Desenho.Texto(g, Text, f, texto, new Rectangle(x + iw, 0, Math.Max(1, Width - x - iw - Tema.S(6)), Height), TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
            }
            if (Focused) ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(ClientRectangle, -Tema.S(4), -Tema.S(4)), texto, fundo);
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

    public class AcaoTexto : Rotulo
    {
        public AcaoTexto() { TabStop = true; Cursor = Cursors.Hand; AccessibleRole = AccessibleRole.Link; }
        public void PerformClick() { if (Enabled) OnClick(EventArgs.Empty); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) { PerformClick(); e.Handled = e.SuppressKeyPress = true; }
            base.OnKeyDown(e);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -2, -2), Tema.Atual.Ouro, CorFundo);
        }
    }

    public class Icone : Base
    {
        public string CorNome = "suave";
        public float Tamanho = 11f;
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (TabStop && (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)) { OnClick(EventArgs.Empty); e.Handled = e.SuppressKeyPress = true; }
            base.OnKeyDown(e);
        }
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
                Desenho.Texto(g, Text, f, texto, new Rectangle(x, 0, Width - x - Tema.S(6), Height), TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
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
            Olho.TabStop = true;
            Olho.AccessibleRole = AccessibleRole.PushButton;
            Olho.AccessibleName = "Mostrar ou ocultar senha";
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
        public Lista() { Cursor = Cursors.Hand; TabStop = true; AccessibleRole = AccessibleRole.ComboBox; }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space || (e.Alt && e.KeyCode == Keys.Down))
            { OnClick(EventArgs.Empty); e.Handled = e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.Up || e.KeyCode == Keys.Down)
            {
                Indice = Math.Max(0, Math.Min(Itens.Count - 1, indice + (e.KeyCode == Keys.Up ? -1 : 1)));
                if (Escolheu != null) Escolheu(this, EventArgs.Empty);
                e.Handled = e.SuppressKeyPress = true;
            }
            base.OnKeyDown(e);
        }
        public int Indice { get { return indice; } set { indice = value; Text = (indice >= 0 && indice < Itens.Count) ? Itens[indice] : ""; AccessibleDescription = Text; Invalidate(); } }
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
            if (Focused) ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(ClientRectangle, -Tema.S(4), -Tema.S(4)), t.Ouro, t.Campo);
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
        public Chave() { Cursor = Cursors.Hand; FundoNome = "fundo"; TabStop = true; AccessibleRole = AccessibleRole.CheckButton; }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) { OnClick(EventArgs.Empty); e.Handled = e.SuppressKeyPress = true; }
            base.OnKeyDown(e);
        }
        public bool Marcado { get { return marcado; } set { marcado = value; AccessibleDescription = value ? "Ligado" : "Desligado"; Invalidate(); } }
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

    // Navegação usa a mesma paleta, incluindo ao trocar de tema sem reiniciar.
    public class Superficie : Panel, ITematico
    {
        public string FundoNome = "fundo";
        public void AplicarTema() { BackColor = Tema.Atual.Cor(FundoNome); Invalidate(); }
        protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(Tema.Atual.Cor(FundoNome)); }
    }

    public class EventoAtividade
    {
        public string Titulo = "", Detalhe = "", CorNome = "suave", Tipo = "outro";
    }

    // Resumo legível; o log completo continua disponível em Detalhes técnicos.
    public class ListaAtividade : Base
    {
        public readonly List<EventoAtividade> Itens = new List<EventoAtividade>();
        public string Vazio = "Sem atividade registrada.";
        public bool Horizontal;
        public ListaAtividade() { AccessibleRole = AccessibleRole.List; }
        public void Definir(EventoAtividade[] itens)
        {
            Itens.Clear();
            if (itens != null) Itens.AddRange(itens);
            var textos = new List<string>();
            foreach (var item in Itens) textos.Add(item.Titulo + ". " + item.Detalhe);
            AccessibleDescription = textos.Count == 0 ? Vazio : string.Join("; ", textos.ToArray());
            Invalidate();
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            Desenho.Preparar(g);
            using (var titulo = new Font("Segoe UI Semibold", 10f))
            using (var detalhe = new Font("Segoe UI", 9f))
            {
                if (Itens.Count == 0)
                {
                    Desenho.Texto(g, Vazio, detalhe, Tema.Atual.Suave, ClientRectangle, TextFormatFlags.WordBreak);
                    return;
                }
                if (Horizontal)
                {
                    int total = Math.Min(3, Itens.Count), largura = Width / total;
                    for (int i = 0; i < total; i++)
                    {
                        var item = Itens[i];
                        int x = i * largura;
                        using (var ponto = new SolidBrush(Tema.Atual.Cor(item.CorNome)))
                            g.FillEllipse(ponto, x + Tema.S(2), Tema.S(9), Tema.S(6), Tema.S(6));
                        Desenho.Texto(g, item.Titulo, titulo, Tema.Atual.Texto,
                            new Rectangle(x + Tema.S(20), 0, largura - Tema.S(32), Tema.S(26)), TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter);
                        Desenho.Texto(g, item.Detalhe, detalhe, Tema.Atual.Suave,
                            new Rectangle(x + Tema.S(20), Tema.S(28), largura - Tema.S(32), Math.Max(1, Height - Tema.S(28))), TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis);
                    }
                    return;
                }
                int altura = Tema.S(72), n = Math.Min(Itens.Count, Math.Max(1, Height / altura));
                for (int i = 0; i < n; i++)
                {
                    var item = Itens[i];
                    int y = i * altura;
                    if (i < n - 1)
                        using (var linha = new Pen(Tema.Atual.Borda, Math.Max(1f, Tema.F)))
                            g.DrawLine(linha, Tema.S(5), y + Tema.S(15), Tema.S(5), y + altura + Tema.S(10));
                    using (var ponto = new SolidBrush(Tema.Atual.Cor(item.CorNome)))
                        g.FillEllipse(ponto, Tema.S(2), y + Tema.S(9), Tema.S(6), Tema.S(6));
                    Desenho.Texto(g, item.Titulo, titulo, Tema.Atual.Texto,
                        new Rectangle(Tema.S(22), y, Width - Tema.S(24), Tema.S(26)), TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter);
                    Desenho.Texto(g, item.Detalhe, detalhe, Tema.Atual.Suave,
                        new Rectangle(Tema.S(22), y + Tema.S(28), Width - Tema.S(24), Tema.S(40)), TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis);
                }
            }
        }
    }

    public class HistoricoAtividade : Base, ITematico
    {
        public readonly List<EventoAtividade> Itens = new List<EventoAtividade>();
        public TextBox Caixa = new TextBox();
        public HistoricoAtividade()
        {
            Caixa.ReadOnly = true; Caixa.BorderStyle = BorderStyle.None;
            Caixa.Multiline = true; Caixa.WordWrap = true;
            Caixa.ScrollBars = ScrollBars.Vertical;
            Caixa.Font = new Font("Segoe UI", 10f);
            Caixa.HandleCreated += delegate { try { CaixaLog.TemaEscuro(Caixa.Handle); } catch { } };
            Caixa.AccessibleName = "Conversas e partidas; texto completo";
            Controls.Add(Caixa); AplicarTema();
        }
        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            Caixa.SetBounds(0, 0, Width, Height);
        }
        public void AplicarTema() { Caixa.BackColor = Tema.Atual.Cartao; Caixa.ForeColor = Tema.Atual.Texto; }
        public void Definir(EventoAtividade[] itens)
        {
            Itens.Clear(); if (itens != null) Itens.AddRange(itens);
            var partes = new List<string>();
            foreach (var item in Itens) partes.Add(item.Titulo + "\r\n" + item.Detalhe.Replace("\r\n", "\n").Replace("\n", "\r\n"));
            var texto = partes.Count == 0 ? "Nenhum evento neste filtro. As conversas são registradas a partir desta atualização." : string.Join("\r\n\r\n", partes.ToArray());
            if (Caixa.Text == texto) return;
            int linha = (int)SendMessage(Caixa.Handle, 0x00CE, IntPtr.Zero, IntPtr.Zero);
            int inicio = Caixa.SelectionStart, tamanho = Caixa.SelectionLength;
            Caixa.Text = texto;
            Caixa.Select(Math.Min(inicio, Caixa.TextLength), Math.Min(tamanho, Caixa.TextLength - Math.Min(inicio, Caixa.TextLength)));
            SendMessage(Caixa.Handle, 0x00B6, IntPtr.Zero, (IntPtr)linha);
            AccessibleDescription = partes.Count == 0 ? texto : Itens.Count + " eventos; use a rolagem para ler.";
        }
        [DllImport("user32.dll")]
        static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
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
# Ícone do painel (Gyarados vermelho): windows/painel.ico em base64, gerado por tools/gerar_icone.py.
$IconePainel = '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'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Distro = 'LoRBots'
$Pasta = $PSScriptRoot
# estavel (a main depois que os testes do GitHub passaram nela), ou a branch de teste com que o
# instalador rodou (ramo.txt). Instalações antigas gravaram "main", que agora vira estavel.
$Ramo = 'estavel'
if ($env:LOR_RAMO) { $Ramo = $env:LOR_RAMO }
elseif (Test-Path (Join-Path $Pasta 'ramo.txt')) { $Ramo = (Get-Content (Join-Path $Pasta 'ramo.txt') -TotalCount 1).Trim() }
if (-not $Ramo -or $Ramo -eq 'main') { $Ramo = 'estavel' }
$Raw = "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$Ramo"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$ArquivoSkin = Join-Path $Pasta 'skin.txt'
$ArquivoLayout = Join-Path $Pasta 'layout.txt'
# Versão deste painel (o instalador grava; o Atualizar regrava depois de trocar o Painel.ps1). Ela é
# conferida à parte da versão do Linux: se a troca do painel falhar depois de o Linux atualizar, o
# próximo Atualizar ainda oferece a troca.
$ArquivoVersao = Join-Path $Pasta 'VERSION'
$Lancador = Join-Path $Pasta 'Painel.vbs'
# Cópia em disco do ícone embutido, para os atalhos (o .lnk só aceita arquivo).
$ArquivoIcone = Join-Path $Pasta 'Painel.ico'
$IconeAtalho = 'shell32.dll,137'
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
    try {
        $bytes = [Convert]::FromBase64String($IconePainel)
        $igual = $false
        if (Test-Path $ArquivoIcone) {
            $atual = [IO.File]::ReadAllBytes($ArquivoIcone)
            $igual = $atual.Length -eq $bytes.Length -and [Convert]::ToBase64String($atual) -eq $IconePainel
        }
        if (-not $igual) { [IO.File]::WriteAllBytes($ArquivoIcone, $bytes) }
        $script:IconeAtalho = "$ArquivoIcone,0"
    } catch { }
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
        # O ícone padrão antigo (shell32,137) e o do PowerShell viram o Gyarados; um ícone que a
        # pessoa escolheu à mão fica.
        $trocarIcone = $l.IconLocation -match '^,|powershell|shell32\.dll,137$' -and $l.IconLocation -ne $IconeAtalho
        if ($l.TargetPath -ne $wscript -or $l.Arguments -ne $argumentos -or $trocarIcone) {
            $l.TargetPath = $wscript
            $l.Arguments = $argumentos
            $l.WorkingDirectory = $Pasta
            if ($trocarIcone) { $l.IconLocation = $IconeAtalho }
            $l.Save()
        }
    }
}

function Invoke-ProcessoPainel {
    param([System.Diagnostics.ProcessStartInfo]$Inicio, [string]$Entrada = '',
          [int]$TimeoutMs = 15000, $Controle = $null)
    $p = $null
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    try {
        $p = [Diagnostics.Process]::Start($Inicio)
        # Drena os dois pipes desde o início, inclusive enquanto envia uma entrada grande.
        $saida = $p.StandardOutput.ReadToEndAsync()
        $erro = $p.StandardError.ReadToEndAsync()
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Entrada)
        $envio = $p.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
        $entradaFechada = $false
        while ($true) {
            if ($Controle -and $Controle.Cancelar) { throw 'Consulta do WSL cancelada.' }
            if ($relogio.ElapsedMilliseconds -ge $TimeoutMs) { throw 'O WSL excedeu o prazo de resposta.' }
            if (-not $entradaFechada -and $envio.IsCompleted) {
                [void]$envio.GetAwaiter().GetResult()
                $p.StandardInput.Close()
                $entradaFechada = $true
            }
            if ($p.HasExited -and $saida.IsCompleted -and $erro.IsCompleted) { break }
            Start-Sleep -Milliseconds 25
        }
        [pscustomobject]@{ Codigo = $p.ExitCode; Saida = $saida.GetAwaiter().GetResult().Trim(); Erro = $erro.GetAwaiter().GetResult().Trim() }
    } catch {
        [pscustomobject]@{ Codigo = 124; Saida = ''; Erro = $_.Exception.Message }
    } finally {
        if ($p) {
            try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(1000) } } catch { }
            $p.Dispose()
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
    # Salvar codigo/time pode consultar a rede por ate 20s no Linux.
    Invoke-ProcessoPainel $psi $Entrada -TimeoutMs 30000
}

function Ler-Estado($Resposta = $null) {
    # Estado e log numa chamada só ao WSL; a resposta pode vir pronta da consulta em segundo plano.
    $r = if ($Resposta) { $Resposta } else { Invoke-Painel @('estado', '--log', '80') }
    if ($r.Codigo -ne 0) { throw (($r.Saida + "`n" + $r.Erro).Trim()) }
    $chaves = $r.Saida.Replace("`r`n", "`n")
    $script:logLinhas = $null
    $script:historicoLinhas = $null
    $h = $chaves.IndexOf("`n---historico---`n")
    if ($h -ge 0) {
        $script:historicoLinhas = @($chaves.Substring($h + 17).Trim() -split "`n")
        $chaves = $chaves.Substring(0, $h)
    }
    $i = $chaves.IndexOf('---log---')
    if ($i -ge 0) {
        $script:logLinhas = @($chaves.Substring($i + 9).Trim() -split "`n")
        $chaves = $chaves.Substring(0, $i)
    }
    $e = @{}
    foreach ($linha in $chaves -split "`n") {
        $i = $linha.IndexOf('=')
        if ($i -gt 0) { $e[$linha.Substring(0, $i)] = $linha.Substring($i + 1).Trim() }
    }
    if (-not $e['bot']) { throw 'O WSL não informou o estado do bot.' }
    $e
}

function Manter-Vivo {
    # O auxiliar é instalado junto do runtime Linux. Perfil e cookies ficam no Windows.
    $login = "\\wsl$\$Distro\opt\lor-bots\Login-Navegador.ps1"
    Rodar-Oculto "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$login`""
    # O WSL desliga o Linux quando nenhum programa do Windows o usa; este processo escondido
    # segura enquanto o bot estiver ligado (e sai sozinho depois). Ele também pede ao Windows para
    # não suspender o PC nesse tempo: com o PC dormindo o timer da partida corre e o bot perde. A
    # tela ainda apaga normalmente; fechar a tampa do notebook segue a configuração do Windows.
    $script = @"
Add-Type -Name Energia -Namespace LoRNativo -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint estado);'
[void][LoRNativo.Energia]::SetThreadExecutionState(0x80000001)
& wsl.exe -d $Distro -u root -e /opt/lor-bots/painel.sh manter-vivo
"@
    $codificado = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Rodar-Oculto "powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand $codificado"
}

function Mensagem([string]$texto, [string]$titulo = 'Painel LoR Bots') {
    [System.Windows.Forms.MessageBox]::Show($texto, $titulo) | Out-Null
}

function Confirmar([string]$texto) {
    [System.Windows.Forms.MessageBox]::Show($texto, 'Painel LoR Bots', 'YesNo', 'Warning', 'Button2') -eq 'Yes'
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
try { $form.Icon = New-Object System.Drawing.Icon((New-Object System.IO.MemoryStream(, [Convert]::FromBase64String($IconePainel)))) }
catch { try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\shell32.dll") } catch { } }

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
$bTema = Novo-BotaoJanela ([string][char]0xE790) 866
$bMin = Novo-BotaoJanela ([string][char]0xE921) 912
$bFechar = Novo-BotaoJanela ([string][char]0xE8BB) 958
$bTema.AccessibleName = 'Escolher layout e tema Lago ou Dragão'
$bMin.AccessibleName = 'Minimizar painel'
$bFechar.AccessibleName = 'Fechar painel'
$bFechar.Fechar = $true
$bMin.Add_Click({ $form.WindowState = 'Minimized' })
$bFechar.Add_Click({ $form.Close() })
$ttTema = New-Object System.Windows.Forms.ToolTip
$ttTema.SetToolTip($bTema, 'Aparência: layout e tema')

# Central de comando: os controles existentes mantêm seus eventos e comandos.
$lateral = New-Object LoR.Superficie
$lateral.FundoNome = 'log'
[void](Pos $lateral 1 60 147 584 $form)
$r = Novo-Rotulo 'SEU BOT' 18 16 114 22 $lateral 'suave' 8.5 $true
$r.FundoNome = 'log'
$nBatalhas = Novo-Botao 'Batalhas' 'Navegacao' ([string][char]0xE7C1) 9 52 129 42 $lateral
$nTimes = Novo-Botao 'Times' 'Navegacao' ([string][char]0xE8F1) 9 102 129 42 $lateral
$nHistorico = Novo-Botao 'Histórico' 'Navegacao' ([string][char]0xE81C) 9 152 129 42 $lateral
$nAjustes = Novo-Botao 'Ajustes' 'Navegacao' ([string][char]0xE713) 9 202 129 42 $lateral
$Navegacao = [ordered]@{ batalhas = $nBatalhas; times = $nTimes; historico = $nHistorico; ajustes = $nAjustes }
foreach ($id in $Navegacao.Keys) { $Navegacao[$id].FundoNome = 'log'; $Navegacao[$id].Tag = $id }
$r = Novo-Rotulo 'SHOWDOWN' 18 488 114 20 $lateral 'suave' 8.5 $true
$r.FundoNome = 'log'
$lNavConta = Novo-Rotulo 'Sem conta' 18 513 116 24 $lateral 'texto' 10 $true
$lNavConta.FundoNome = 'log'
$lNavEstado = Novo-Rotulo 'Configure em Ajustes' 18 539 118 23 $lateral 'suave' 8.5
$lNavEstado.FundoNome = 'log'

$lTitulo = Novo-Rotulo 'Central de batalhas' 170 76 426 34 $form 'texto' 18 $true
$lTitulo.FundoNome = 'fundo'
$lSubtitulo = Novo-Rotulo 'Ladder oficial · Regulamento M-C' 170 111 426 22 $form 'suave' 9.5
$lSubtitulo.FundoNome = 'fundo'
$bDesafiar = Novo-Botao 'Desafiar jogador' 'Neutro' ([string][char]0xE7C1) 812 82 192 38 $form
$bDesafiar.FundoNome = 'fundo'
# Atalho direto para os replays do bot no Showdown, à vista em qualquer seção.
$bReplays = Novo-Botao 'Histórico de partidas' 'Neutro' ([string][char]0xE81C) 608 82 192 38 $form
$bReplays.FundoNome = 'fundo'

# Partida atual: a identidade, o placar e os comandos não disputam a mesma linha.
$cStatus = Novo-Cartao '' '' 170 137 520 270
$cStatus.Destaque = $true
$pBot = New-Object LoR.Bolinha
[void](Pos $pBot 18 16 20 20 $cStatus)
$lBot = Novo-Rotulo 'Carregando…' 46 10 456 32 $cStatus 'texto' 13 $true
$selo = New-Object LoR.Pilula
[void](Pos $selo 18 46 250 26 $cStatus)
$selo.Visible = $false
$lInfo = Novo-Rotulo 'Ligando o Linux dos bots…' 18 78 484 22 $cStatus 'suave' 9.5
$lSeuBotCaption = Novo-Rotulo 'SEU BOT' 18 105 170 18 $cStatus 'suave' 8 $true
$lRivalCaption = Novo-Rotulo 'ADVERSÁRIO' 310 105 192 18 $cStatus 'suave' 8 $true
$lRivalCaption.Alinhar = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter'
$lNos = Novo-Rotulo '—' 18 125 170 25 $cStatus 'texto' 11 $true
$lRival = Novo-Rotulo 'Aguardando adversário' 310 125 192 25 $cStatus 'texto' 11 $true
$lRival.Alinhar = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter'
$lPlacar = Novo-Rotulo '—' 190 107 120 53 $cStatus 'ouro' 28 $true
$lPlacar.Alinhar = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter'
$lPlacarLegenda = Novo-Rotulo 'sem partida' 177 157 146 21 $cStatus 'suave' 8.5
$lPlacarLegenda.Alinhar = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter'
$lTimeAtivo = Novo-Rotulo '' 18 151 170 22 $cStatus 'suave' 9
$lPokemon = Novo-Rotulo '' 325 151 177 22 $cStatus 'suave' 9
$lPokemon.Alinhar = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter'
$bVer = Novo-Botao 'Acompanhar partida' 'Primario' ([string][char]0xE8A7) 18 183 226 36 $cStatus
$bLigar = Novo-Botao 'Iniciar bot' 'Primario' ([string][char]0x25B6) 18 183 226 36 $cStatus
$bDesligar = Novo-Botao 'Parar ao fim da série' 'Neutro' ([string][char]0x25A0) 256 183 246 36 $cStatus
$sepStatus = New-Object LoR.Divisor
[void](Pos $sepStatus 18 227 484 2 $cStatus)
$chip = New-Object LoR.Pilula
$chip.Tipo = 'neutra'
$chip.Simbolo = [string][char]0xE950
[void](Pos $chip 18 236 116 24 $cStatus)
$chip.Visible = $false
# Elo da conta no ladder oficial (do cache do painel.sh; GXE e partidas na dica).
$pElo = New-Object LoR.Pilula
$pElo.Tipo = 'neutra'
$pElo.Simbolo = [string][char]0xE734
[void](Pos $pElo 144 236 110 24 $cStatus)
$pElo.Visible = $false
$bAgora = Novo-Botao 'Interromper agora' 'Perigo' ([string][char]0xE7BA) 302 232 200 32 $cStatus
$bAgora.SemBorda = $true
$ttTema.SetToolTip($bAgora, 'Interrompe a partida atual. O bot pode perder por W.O.')
$ttTema.SetToolTip($lRival, '')

# Os mesmos seletores aparecem em Batalhas e Times, preservando valores não aplicados.
$cJogo = Novo-Cartao 'Próximas partidas' 'Valem após a partida ou série atual.' 170 420 520 160
$lFormato = Novo-Rotulo 'Formato' 18 46 84 19 $cJogo 'suave' 9
$lTimer = Novo-Rotulo 'Timer' 114 46 118 19 $cJogo 'suave' 9
$lTimeCampo = Novo-Rotulo 'Time' 244 46 258 19 $cJogo 'suave' 9
$cFormato = Nova-Lista @('BO3', 'BO1') 18 68 84 34 $cJogo
$cFormato.AccessibleName = 'Formato das próximas partidas'
$cTimer = Nova-Lista @('Ligado', 'Desligado') 114 68 118 34 $cJogo
$cTimer.AccessibleName = 'Timer das próximas partidas'
$cTime = Nova-Lista @('Padrão (MC371/MC196)') 244 68 258 34 $cJogo
$cTime.AccessibleName = 'Time das próximas partidas'
$lConfigStatus = Novo-Rotulo 'Selecione e aplique para trocar.' 18 111 310 40 $cJogo 'suave' 9
$lConfigStatus.Alinhar = [System.Windows.Forms.TextFormatFlags]'WordBreak, VerticalCenter'
$bAplicar = Novo-Botao 'Aplicar alterações' 'Neutro' '' 342 115 160 34 $cJogo
$bAddTime = Novo-Botao 'Adicionar time' 'Contorno' ([string][char]0xE710) 20 163 172 36 $cJogo
$bRemTime = Novo-Botao 'Remover time' 'Neutro' ([string][char]0xE74D) 206 163 172 36 $cJogo
$bAddTime.Visible = $false
$bRemTime.Visible = $false

# Atividade estruturada, com o log bruto acessível sem perder filtros ou recolhimento.
$cLog = Novo-Cartao 'Atividade' '' 706 137 298 443
$cFiltro = Nova-Lista @('Todos', 'Partidas', 'Avisos') 18 47 114 30 $cLog
$cFiltro.AccessibleName = 'Filtrar atividade'
$bRecolher = Novo-Botao 'Recolher' 'Fantasma' '' 188 10 94 30 $cLog
$bTecnico = Novo-Botao 'Log técnico' 'Neutro' ([string][char]0xE756) 144 47 138 30 $cLog
$atividade = New-Object LoR.ListaAtividade
$atividade.AccessibleName = 'Atividade recente'
[void](Pos $atividade 18 94 262 294 $cLog)
$tLog = New-Object LoR.CaixaLog
$tLog.Caixa.AccessibleName = 'Log técnico completo do bot'
[void](Pos $tLog 16 90 266 303 $cLog)
$tLog.Visible = $false
$bAbrirHistorico = Novo-Botao 'Ver histórico e replays' 'Fantasma' '' 18 403 262 28 $cLog

# Conexões resumidas; os campos sensíveis ficam na seção Ajustes.
$cResumoColeta = Novo-Cartao '' '' 170 593 410 50
[void](Novo-Rotulo 'Coleta de partidas' 14 4 275 21 $cResumoColeta 'texto' 10 $true)
$lResumoColeta = Novo-Rotulo 'Verificando código…' 14 25 282 19 $cResumoColeta 'suave' 8.5
$bGerenciarColeta = Novo-Botao 'Gerenciar' 'Fantasma' '' 305 9 94 32 $cResumoColeta
$cResumoConta = Novo-Cartao '' '' 594 593 410 50
[void](Novo-Rotulo 'Conta do Showdown' 14 4 278 21 $cResumoConta 'texto' 10 $true)
$lResumoConta = Novo-Rotulo 'Verificando conta…' 14 25 285 19 $cResumoConta 'suave' 8.5
$bEditarConta = Novo-Botao 'Editar' 'Fantasma' '' 319 9 80 32 $cResumoConta

# Ajustes: os mesmos campos e eventos de salvamento do painel anterior.
$cConta = Novo-Cartao 'Conta do Showdown' '' 170 137 405 286
[void](Novo-Rotulo 'Usuário' 20 50 170 20 $cConta)
$xBloquearBots = New-Object LoR.Chave
$xBloquearBots.FundoNome = 'cartao'
$xBloquearBots.Marcado = $true
$xBloquearBots.AccessibleName = 'Bloquear bots no ladder'
[void](Pos $xBloquearBots 202 50 36 20 $cConta)
$lBloquearBots = Novo-Rotulo 'Bloquear bots' 248 50 125 20 $cConta 'texto' 9.5
$lBloquearBots.Cursor = 'Hand'
$ttTema.SetToolTip($lBloquearBots, 'Ligado: /blockbots. Desligado: /allowbots. Vale no próximo login ou antes da próxima busca no ladder.')
$ttTema.SetToolTip($xBloquearBots, 'Bloquear bots no ladder (/blockbots) ou permitir (/allowbots).')
$tUsuario = Novo-Campo '' 20 72 365 38 $cConta
$tUsuario.Caixa.AccessibleName = 'Usuário do Showdown'
$lLoginNavegador = Novo-Rotulo 'Login no navegador ao ligar o bot' 20 116 365 20 $cConta 'suave' 9.5
$ttTema.SetToolTip($lLoginNavegador, 'A senha é digitada apenas no site oficial do Showdown.')
$xDecisoesInstantaneas = New-Object LoR.Chave
$xDecisoesInstantaneas.FundoNome = 'cartao'
$xDecisoesInstantaneas.Marcado = $false
$xDecisoesInstantaneas.AccessibleName = 'Decisões Instantâneas: Não'
[void](Pos $xDecisoesInstantaneas 20 142 36 20 $cConta)
$lDecisoesInstantaneas = Novo-Rotulo 'Decisões Instantâneas' 66 142 235 22 $cConta 'texto' 9.5
$lDecisoesInstantaneas.Cursor = 'Hand'
$lDecisoesValor = Novo-Rotulo 'Não' 303 142 68 22 $cConta 'suave' 9.5
$lDecisoesValor.Cursor = 'Hand'
$ajudaDecisoes = 'Sim: envia assim que a IA termina o cálculo. Não: usa o ritmo da personalidade da conta, com mais tempo para escolher os Pokémon e menos para trocas forçadas. Reduz a espera quando há pouco tempo no relógio.'
foreach ($c in @($xDecisoesInstantaneas, $lDecisoesInstantaneas, $lDecisoesValor)) { $ttTema.SetToolTip($c, $ajudaDecisoes) }
$xEsperarBots = New-Object LoR.Chave
$xEsperarBots.FundoNome = 'cartao'
$xEsperarBots.Marcado = $true
$xEsperarBots.AccessibleName = 'Esperar bots adversários conhecidos saírem da fila'
[void](Pos $xEsperarBots 20 170 36 20 $cConta)
$lEsperarBots = Novo-Rotulo 'Esperar bots conhecidos' 66 170 305 22 $cConta 'texto' 9.5
$lEsperarBots.Cursor = 'Hand'
$ajudaEsperaBots = 'Ligado: espera até 10 minutos por bots adversários conhecidos. Desligado: pula essa espera, inclusive se já estiver esperando. A fila do nosso time e a pausa entre partidas continuam iguais.'
$ttTema.SetToolTip($lEsperarBots, $ajudaEsperaBots)
$ttTema.SetToolTip($xEsperarBots, $ajudaEsperaBots)
$xEsperarColmeia = New-Object LoR.Chave
$xEsperarColmeia.FundoNome = 'cartao'
$xEsperarColmeia.Marcado = $true
$xEsperarColmeia.AccessibleName = 'Esperar bots da colmeia saírem da fila'
[void](Pos $xEsperarColmeia 20 198 36 20 $cConta)
$lEsperarColmeia = Novo-Rotulo 'Esperar bots da colmeia' 66 198 305 22 $cConta 'texto' 9.5
$lEsperarColmeia.Cursor = 'Hand'
$ajudaColmeia = 'Ligado: espera a vez entre os bots do nosso time. Desligado: busca junto com eles e encerra uma espera em curso. Os nossos bots poderão se enfrentar. Religar vale na próxima busca.'
$ttTema.SetToolTip($lEsperarColmeia, $ajudaColmeia)
$ttTema.SetToolTip($xEsperarColmeia, $ajudaColmeia)
$bConta = Novo-Botao 'Salvar conta' 'Primario' '' 234 228 151 38 $cConta
# Saudações do perfil no começo e no fim; vale já na próxima partida.
$xChat = New-Object LoR.Chave
$xChat.FundoNome = 'cartao'
$xChat.Marcado = $true
$xChat.AccessibleName = 'Saudações da personalidade no chat das partidas'
[void](Pos $xChat 20 237 36 20 $cConta)
$lChat = Novo-Rotulo 'Saudações no chat' 66 230 160 34 $cConta 'texto' 9.5
$lChat.Cursor = 'Hand'
$ttTema.SetToolTip($lChat, 'O bot varia as saudações conforme sua personalidade: no começo da partida (no Bo3, da série) e no fim de cada jogo. A apresentação identifica que é um bot LoR.')
$cColeta = Novo-Cartao 'Coleta de partidas' 'Código para treino e Discord' 591 137 413 286
$tCodigo = Novo-Campo 'Cole seu código' 20 72 373 38 $cColeta
$tCodigo.Caixa.AccessibleName = 'Código da coleta de partidas'
$tCodigo.Caixa.UseSystemPasswordChar = $true
$pCodigo = New-Object LoR.Bolinha
$pCodigo.Brilho = $false
$pCodigo.CorNome = 'ambar'
[void](Pos $pCodigo 22 131 10 10 $cColeta)
$lCodigo = Novo-Rotulo 'Não salvo' 40 120 353 32 $cColeta 'ambar' 9.5
$lCodigo.Alinhar = [System.Windows.Forms.TextFormatFlags]'WordBreak, VerticalCenter'
$lColetaAjuda = Novo-Rotulo 'As partidas alimentam o treino do time e o canal do Discord.' 20 166 373 44 $cColeta 'suave' 10
$lColetaAjuda.Alinhar = [System.Windows.Forms.TextFormatFlags]'WordBreak'
$bCodigo = Novo-Botao 'Salvar código' 'Neutro' '' 242 228 151 38 $cColeta
# Postar as séries deste PC no Discord do time; desligado, as partidas ainda vão para o treino.
$xDiscord = New-Object LoR.Chave
$xDiscord.FundoNome = 'cartao'
$xDiscord.Marcado = $true
$xDiscord.AccessibleName = 'Postar as partidas no Discord'
[void](Pos $xDiscord 20 237 36 20 $cColeta)
$lDiscord = Novo-Rotulo 'Postar no Discord' 66 230 166 34 $cColeta 'texto' 9.5
$lDiscord.Cursor = 'Hand'
$ttTema.SetToolTip($lDiscord, 'Desligado, as partidas continuam indo para o treino do time, mas não aparecem no canal.')

$cTimesAjuda = Novo-Cartao 'Gerenciar seus times' '' 170 384 834 180
$r = Novo-Rotulo "Adicionar time: cole um link do pokepast.es ou o export do Showdown. O conteúdo é validado antes de salvar.`n`nPara trocar, escolha o time na lista e aplique. O bot conclui a partida ou série atual antes de usar a nova configuração." 20 51 794 109 $cTimesAjuda 'suave' 11
$r.Alinhar = [System.Windows.Forms.TextFormatFlags]'WordBreak'

# Histórico conserva tanto os replays no Showdown quanto os arquivos locais.
$cHistorico = Novo-Cartao 'Histórico e replays' 'Abra os replays salvos ou os arquivos de partidas neste PC.' 170 137 834 443
$bHistorico = Novo-Botao 'Abrir histórico de replays' 'Primario' ([string][char]0xE8A7) 20 65 267 38 $cHistorico
$bPastaPartidas = Novo-Botao 'Abrir pasta de partidas' 'Neutro' ([string][char]0xE8B7) 301 65 251 38 $cHistorico
[void](Novo-Rotulo 'Atividade recente · conversas salvas neste PC' 20 121 570 26 $cHistorico 'suave' 10)
$cFiltroHistorico = Nova-Lista @('Todos', 'Partidas', 'Mensagens') 634 117 180 32 $cHistorico
$cFiltroHistorico.AccessibleName = 'Filtrar histórico'
$atividadeHistorico = New-Object LoR.HistoricoAtividade
$atividadeHistorico.AccessibleName = 'Histórico de partidas e mensagens'
[void](Pos $atividadeHistorico 20 157 794 272 $cHistorico)

# Rodapé permanece fixo ao navegar ou recolher a atividade.
$xAuto = New-Object LoR.Chave
$xAuto.AccessibleName = 'Iniciar o bot com o Windows'
[void](Pos $xAuto 22 658 36 20 $form)
$lAuto = Novo-Rotulo 'Iniciar com o Windows' 68 651 280 32 $form 'texto' 9.5
$lAuto.FundoNome = 'fundo'
$lAuto.Cursor = 'Hand'
$lAtualizar = New-Object LoR.AcaoTexto
$lAtualizar.Text = 'Verificar atualização'
$lAtualizar.CorNome = 'ouro'
$lAtualizar.Tamanho = 9.5
[void](Pos $lAtualizar 785 651 219 32 $form)
$lAtualizar.FundoNome = 'fundo'
$lAtualizar.Sublinhado = $true
$lAtualizar.Alinhar = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter'
$lVersao = Novo-Rotulo 'Versão' 519 651 254 32 $form 'suave' 9.5
$lVersao.FundoNome = 'fundo'
$lVersao.Alinhar = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter'
$divRodape = New-Object LoR.Divisor
$divRodape.FundoNome = 'fundo'
[void](Pos $divRodape 778 658 2 20 $form)
$Atalho = $AtalhoLigar
$xAuto.Marcado = Test-Path $Atalho
$script:secao = 'batalhas'
$script:recolhido = $false
$script:logTecnico = $false

function Arrumar-Atividade {
    $altura = if ($script:layout -eq 'central') { 443 } else { 123 }
    $cLog.Height = S $(if ($script:recolhido) { 43 } else { $altura })
    $bRecolher.Text = if ($script:recolhido) { 'Expandir' } else { 'Recolher' }
    $cFiltro.Visible = -not $script:recolhido
    $bTecnico.Visible = -not $script:recolhido
    $bAbrirHistorico.Visible = -not $script:recolhido
    $atividade.Visible = -not $script:recolhido -and -not $script:logTecnico
    $tLog.Visible = -not $script:recolhido -and $script:logTecnico
    $bTecnico.Text = if ($script:logTecnico) { 'Resumo' } else { 'Log técnico' }
}

function Mostrar-Secao([string]$secao) {
    if (-not $Navegacao.Contains($secao)) { return }
    if ($script:layout -eq 'refinado') { $secao = 'batalhas' }
    $script:secao = $secao
    $form.SuspendLayout()
    try {
        foreach ($item in $script:LayoutBase) {
            if ($item.Controle.Parent -ne $item.Pai) { $item.Pai.Controls.Add($item.Controle) }
            $item.Controle.Bounds = $item.Bounds
        }
        $atividade.Horizontal = $false
        $bAplicar.Text = 'Aplicar alterações'
        $bAbrirHistorico.Text = 'Ver histórico e replays'
        $lTitulo.Visible = $true
        $lSubtitulo.Visible = $true
        $bReplays.Visible = $true
        $lColetaAjuda.Visible = $true
        $lDiscord.Alinhar = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter'
        $lConfigStatus.Visible = $true
        $lateral.Visible = $true
        foreach ($c in $lateral.Controls) { $c.Visible = $true }
        $batalhas = $secao -eq 'batalhas'
        foreach ($c in @($cStatus, $cLog, $cResumoColeta, $cResumoConta)) { $c.Visible = $batalhas }
        $cJogo.Visible = $secao -in @('batalhas', 'times')
        $cConta.Visible = $secao -eq 'ajustes'
        $cColeta.Visible = $secao -eq 'ajustes'
        $cTimesAjuda.Visible = $secao -eq 'times'
        $cHistorico.Visible = $secao -eq 'historico'
        $titulos = @{ batalhas = 'Central de batalhas'; times = 'Seus times'; historico = 'Histórico de partidas'; ajustes = 'Ajustes' }
        $subtitulos = @{ batalhas = 'Ladder oficial · Regulamento M-C'; times = 'Formato, timer e times das próximas partidas.'; historico = 'Resultados, mensagens, replays e arquivos locais.'; ajustes = 'Conta do Showdown e envio de partidas.' }
        $lTitulo.Text = $titulos[$secao]
        $lSubtitulo.Text = $subtitulos[$secao]
        if ($secao -eq 'historico' -and $script:resumoHoje) { $lSubtitulo.Text = $script:resumoHoje }
        foreach ($id in $Navegacao.Keys) { $Navegacao[$id].Selecionado = $id -eq $secao; $Navegacao[$id].Invalidate() }
        if ($secao -eq 'times') {
            $cJogo.SetBounds((S 170), (S 137), (S 834), (S 232))
            $cJogo.Titulo = 'Configuração de partidas'
            $cFormato.SetBounds((S 20), (S 68), (S 120), (S 36))
            $cTimer.SetBounds((S 154), (S 68), (S 140), (S 36))
            $cTime.SetBounds((S 308), (S 68), (S 506), (S 36))
            $lFormato.SetBounds((S 20), (S 46), (S 120), (S 19))
            $lTimer.SetBounds((S 154), (S 46), (S 140), (S 19))
            $lTimeCampo.SetBounds((S 308), (S 46), (S 506), (S 19))
            $lConfigStatus.SetBounds((S 20), (S 116), (S 794), (S 35))
            $bAplicar.SetBounds((S 654), (S 163), (S 160), (S 36))
        } else {
            $cJogo.SetBounds((S 170), (S 420), (S 520), (S 160))
            $cJogo.Titulo = 'Próximas partidas'
            $cFormato.SetBounds((S 18), (S 68), (S 84), (S 34))
            $cTimer.SetBounds((S 114), (S 68), (S 118), (S 34))
            $cTime.SetBounds((S 244), (S 68), (S 258), (S 34))
            $lFormato.SetBounds((S 18), (S 46), (S 84), (S 19))
            $lTimer.SetBounds((S 114), (S 46), (S 118), (S 19))
            $lTimeCampo.SetBounds((S 244), (S 46), (S 258), (S 19))
            $lConfigStatus.SetBounds((S 18), (S 111), (S 310), (S 40))
            $bAplicar.SetBounds((S 342), (S 115), (S 160), (S 34))
        }
        $bAddTime.Visible = $secao -eq 'times'
        $bRemTime.Visible = $secao -eq 'times'
        Aplicar-Layout
        $cJogo.Invalidate()
        Arrumar-Atividade
    } finally { $form.ResumeLayout($true) }
}

foreach ($id in $Navegacao.Keys) { $Navegacao[$id].Add_Click({ param($s) Mostrar-Secao $s.Tag }) }
$bGerenciarColeta.Add_Click({ Mostrar-Secao 'ajustes'; [void]$tCodigo.Caixa.Focus() })
$bEditarConta.Add_Click({ Mostrar-Secao 'ajustes'; [void]$tUsuario.Caixa.Focus() })
$bAbrirHistorico.Add_Click({ if ($script:layout -eq 'refinado') { $bHistorico.PerformClick() } else { Mostrar-Secao 'historico' } })
foreach ($lista in @($cFormato, $cTimer, $cTime)) {
    $lista.add_Escolheu({ $lConfigStatus.Text = 'Alterações não aplicadas.'; $lConfigStatus.CorNome = 'ambar' })
}
$Layouts = [ordered]@{ central = 'Central de comando'; arena = 'Arena em foco'; refinado = 'Painel refinado' }
$script:layout = 'central'
try { $salvo = (Get-Content $ArquivoLayout -TotalCount 1 -ErrorAction Stop).Trim(); if ($Layouts.Contains($salvo)) { $script:layout = $salvo } } catch { }

function Memorizar-Layout($pai) {
    foreach ($c in $pai.Controls) {
        $script:LayoutBase.Add([pscustomobject]@{ Controle = $c; Pai = $c.Parent; Bounds = $c.Bounds })
        Memorizar-Layout $c
    }
}
$script:LayoutBase = New-Object System.Collections.Generic.List[object]
Memorizar-Layout $form

function Posicionar-Status {
    if ($script:layout -eq 'refinado') {
        $selo.SetBounds((S 300), (S 14), [Math]::Min((S 186), $selo.LarguraIdeal()), (S 26))
        $chip.SetBounds((S 498), (S 14), [Math]::Min((S 104), $chip.LarguraIdeal()), (S 26))
        # Embaixo do chip de memória, na linha da informação (que encurta para não encostar).
        $pElo.SetBounds((S 498), (S 41), [Math]::Min((S 104), $pElo.LarguraIdeal()), (S 22))
        $lInfo.Width = if ($pElo.Visible) { S 468 } else { S 580 }
    } else {
        $selo.SetBounds((S 18), (S 46), [Math]::Min(($cStatus.Width - (S 36)), $selo.LarguraIdeal()), (S 26))
        $chip.Width = [Math]::Min((S 200), $chip.LarguraIdeal())
        # Ao lado do chip de memória, sem chegar no "Interromper agora".
        $x = if ($chip.Visible) { $chip.Right + (S 10) } else { $chip.Left }
        $pElo.SetBounds($x, $chip.Top, [Math]::Min($pElo.LarguraIdeal(), $bAgora.Left - $x - (S 10)), $chip.Height)
    }
}

function Aplicar-Layout {
    if ($script:layout -eq 'central') { return }
    if ($script:layout -eq 'arena') {
        $lateral.SetBounds((S 1), (S 60), (S 1022), (S 48))
        foreach ($c in $lateral.Controls) { $c.Visible = $c -is [LoR.Botao] }
        $i = 0
        foreach ($n in $Navegacao.Values) { $n.SetBounds((S (20 + $i * 160)), (S 4), (S 145), (S 40)); $i++ }
        $lTitulo.SetBounds((S 22), (S 116), (S 570), (S 34))
        if ($script:secao -eq 'batalhas') { $lTitulo.Text = 'Arena de batalhas' }
        $lSubtitulo.SetBounds((S 22), (S 151), (S 570), (S 22))
        $bDesafiar.SetBounds((S 812), (S 122), (S 192), (S 38))
        $bReplays.SetBounds((S 608), (S 122), (S 192), (S 38))
        if ($script:secao -eq 'batalhas') {
            $cStatus.SetBounds((S 22), (S 181), (S 612), (S 270))
            $lBot.Width = S 548
            foreach ($c in @($lRivalCaption, $lRival, $lPokemon)) { $c.Left += S 92 }
            foreach ($c in @($lPlacar, $lPlacarLegenda)) { $c.Left += S 46 }
            $bVer.Width = S 272; $bLigar.Width = S 272
            $bDesligar.SetBounds((S 302), (S 183), (S 292), (S 36))
            $bAgora.Left = S 394; $sepStatus.Width = S 576
            $cJogo.SetBounds((S 650), (S 181), (S 354), (S 270))
            $cFormato.SetBounds((S 18), (S 68), (S 104), (S 36))
            $cTimer.SetBounds((S 134), (S 68), (S 202), (S 36))
            $lTimer.Left = S 134
            $lTimeCampo.SetBounds((S 18), (S 113), (S 318), (S 19))
            $cTime.SetBounds((S 18), (S 135), (S 318), (S 36))
            $lConfigStatus.SetBounds((S 18), (S 179), (S 318), (S 32))
            $bAplicar.SetBounds((S 18), (S 220), (S 318), (S 36))
            $cLog.SetBounds((S 22), (S 466), (S 982), (S 123))
            $cResumoColeta.SetBounds((S 22), (S 603), (S 484), (S 46))
            $cResumoConta.SetBounds((S 520), (S 603), (S 484), (S 46))
            $bGerenciarColeta.Left = S 379; $bEditarConta.Left = S 393
        } elseif ($script:secao -eq 'times') {
            $cJogo.SetBounds((S 22), (S 181), (S 982), (S 232))
            $cTime.Width = S 654; $lTimeCampo.Width = S 654
            $bAplicar.Left = S 802
            $cTimesAjuda.SetBounds((S 22), (S 428), (S 982), (S 180))
        } elseif ($script:secao -eq 'ajustes') {
            $cConta.SetBounds((S 22), (S 181), (S 483), (S 286))
            $cColeta.SetBounds((S 521), (S 181), (S 483), (S 286))
            $tUsuario.Width = S 443; $tCodigo.Width = S 443
            $bConta.Left = S 312; $bCodigo.Left = S 312
            $lCodigo.Width = S 423; $lColetaAjuda.Width = S 443
        } else {
            $cHistorico.SetBounds((S 22), (S 181), (S 982), (S 443))
            $atividadeHistorico.Width = S 942
        }
    } else {
        # Painel refinado mantém tudo na mesma tela, com a densidade do painel clássico.
        # Sem cabeçalho aqui: o botão Histórico do cartão de atividade já abre os replays.
        $lateral.Visible = $false; $lTitulo.Visible = $false; $lSubtitulo.Visible = $false; $bReplays.Visible = $false
        $cResumoColeta.Visible = $false; $cResumoConta.Visible = $false
        $cConta.Visible = $true; $cColeta.Visible = $true
        $cStatus.SetBounds((S 13), (S 69), (S 998), (S 150))
        $lBot.Width = S 238
        $lInfo.SetBounds((S 18), (S 42), (S 580), (S 22))
        $lSeuBotCaption.SetBounds((S 18), (S 67), (S 182), (S 18))
        $lRivalCaption.SetBounds((S 358), (S 67), (S 232), (S 18))
        $lNos.SetBounds((S 18), (S 87), (S 182), (S 24))
        $lRival.SetBounds((S 358), (S 87), (S 232), (S 24))
        $lTimeAtivo.SetBounds((S 18), (S 113), (S 182), (S 22))
        $lPokemon.SetBounds((S 358), (S 113), (S 232), (S 22))
        $lPlacar.SetBounds((S 214), (S 65), (S 126), (S 50))
        $lPlacarLegenda.SetBounds((S 204), (S 115), (S 146), (S 21))
        $bVer.SetBounds((S 616), (S 14), (S 350), (S 36)); $bLigar.Bounds = $bVer.Bounds
        $bDesligar.SetBounds((S 616), (S 61), (S 350), (S 36))
        $bAgora.SetBounds((S 674), (S 106), (S 238), (S 32))
        $sepStatus.SetBounds((S 605), (S 12), (S 2), (S 126))
        $cJogo.SetBounds((S 13), (S 230), (S 595), (S 164))
        $cJogo.Titulo = 'Configuração de partidas'
        $lFormato.SetBounds((S 20), (S 50), (S 80), (S 20))
        $lTimer.SetBounds((S 110), (S 50), (S 124), (S 20))
        $lTimeCampo.SetBounds((S 244), (S 50), (S 222), (S 20))
        $cFormato.SetBounds((S 20), (S 72), (S 80), (S 34))
        $cTimer.SetBounds((S 110), (S 72), (S 124), (S 34))
        $cTime.SetBounds((S 244), (S 72), (S 222), (S 34))
        $bAplicar.Text = 'Aplicar'
        $bAplicar.SetBounds((S 478), (S 72), (S 98), (S 34))
        $lConfigStatus.Visible = $false
        $bAddTime.Visible = $true; $bRemTime.Visible = $true
        $bAddTime.SetBounds((S 20), (S 124), (S 150), (S 32))
        $bRemTime.SetBounds((S 182), (S 124), (S 150), (S 32))
        $cJogo.Controls.Add($bDesafiar)
        $bDesafiar.SetBounds((S 344), (S 124), (S 231), (S 32))
        $cConta.SetBounds((S 618), (S 230), (S 393), (S 277))
        $tUsuario.Width = S 353
        $bConta.Left = S 222
        $cColeta.SetBounds((S 13), (S 405), (S 595), (S 102))
        $tCodigo.SetBounds((S 20), (S 50), (S 419), (S 32))
        $bCodigo.SetBounds((S 453), (S 50), (S 122), (S 32))
        $pCodigo.SetBounds((S 22), (S 88), (S 8), (S 8))
        $lCodigo.SetBounds((S 40), (S 84), (S 535), (S 16))
        $lColetaAjuda.Visible = $false
        $lDiscord.SetBounds((S 330), (S 10), (S 199), (S 30))
        $lDiscord.Alinhar = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter'
        $xDiscord.SetBounds((S 539), (S 15), (S 36), (S 20))
        $cLog.SetBounds((S 13), (S 517), (S 998), (S 123))
    }
    if ($script:secao -eq 'batalhas') {
        $atividade.Horizontal = $true
        $atividade.SetBounds((S 18), (S 47), (S ($cLog.Width / [LoR.Tema]::F - 36)), (S 68))
        $tLog.SetBounds((S 16), (S 47), ($cLog.Width - (S 32)), (S 68))
        $cFiltro.SetBounds(($cLog.Width - (S 378)), (S 10), (S 114), (S 30))
        $bTecnico.SetBounds(($cLog.Width - (S 252)), (S 10), (S 138), (S 30))
        $bRecolher.SetBounds(($cLog.Width - (S 110)), (S 10), (S 94), (S 30))
        $bAbrirHistorico.Text = 'Histórico'
        $bAbrirHistorico.SetBounds((S 174), (S 10), (S 114), (S 30))
    }
    Posicionar-Status
}

function Escolher-Layout([string]$id) {
    if (-not $Layouts.Contains($id)) { return }
    $script:layout = $id
    try { Set-Content -LiteralPath $ArquivoLayout -Value $id -Encoding ASCII } catch { }
    Mostrar-Secao $script:secao
}
Mostrar-Secao 'batalhas'


# Menu de aparência.
function Escolher-Tema($id) {
    [LoR.Tema]::Atual = $Temas[$id]
    try { Set-Content -Path $ArquivoSkin -Value $id -Encoding ASCII } catch { }
    $form.AplicarTema()
    Arrumar-Status
}
function Criar-MenuAparencia {
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $m.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object LoR.CoresMenu))
    $m.ShowImageMargin = $false
    $m.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
    foreach ($id in $Layouts.Keys) {
        $atual = $script:layout -eq $id
        $it = New-Object System.Windows.Forms.ToolStripMenuItem((@('    ', '✓ ')[[int]$atual]) + $Layouts[$id])
        $it.ForeColor = if ($atual) { [LoR.Tema]::Atual.Ouro } else { [LoR.Tema]::Atual.Texto }
        $it.Tag = $id
        $it.Add_Click({ param($s) Escolher-Layout $s.Tag })
        [void]$m.Items.Add($it)
    }
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    foreach ($id in $Temas.Keys) {
        $atual = [LoR.Tema]::Atual.Id -eq $id
        $it = New-Object System.Windows.Forms.ToolStripMenuItem((@('    ', '✓ ')[[int]$atual]) + $Temas[$id].Nome)
        $it.ForeColor = if ($atual) { [LoR.Tema]::Atual.Ouro } else { [LoR.Tema]::Atual.Texto }
        $it.Tag = $id
        $it.Add_Click({ param($s) Escolher-Tema $s.Tag })
        [void]$m.Items.Add($it)
    }
    $m
}
$bTema.Add_Click({
    $m = Criar-MenuAparencia
    $m.Show($bTema, (New-Object System.Drawing.Point(((S 46) - (S 250)), $bTema.Height)))
})

# ---------------------------------------------------------------------------------------------
# Estado

$script:estado = @{}
$script:versaoNova = $null
$script:recolhido = $false

# Respostas de comandos chegam como PMs sintéticas e o poke-env as registra como WARNING.
# Só reclassifica os textos conhecidos do servidor (~); erros reais continuam em Avisos.
function Ler-RespostaShowdown([string]$linha) {
    $restricaoChat = "Due to spam from your internet provider, you can't speak except to staff."
    $mensagem = $linha -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d+ - .*? - (?:WARNING|CRITICAL) - ', ''
    if ($mensagem.StartsWith("showdown chat restricted: $restricaoChat")) {
        return [pscustomobject]@{ Titulo = 'Chat restrito pelo Showdown'; Detalhe = 'Restrição do provedor. Mensagens automáticas suspensas nesta conexão.'; Tipo = 'aviso'; CorNome = 'ambar' }
    }
    $erroChatAntigo = '^' + [regex]::Escape("Unexpected error message: ['', 'error', ") + "[""']" + [regex]::Escape($restricaoChat)
    if ($mensagem -match $erroChatAntigo) {
        return [pscustomobject]@{ Titulo = 'Chat restrito pelo Showdown'; Detalhe = 'O Showdown restringiu o chat desta conexão por causa do provedor.'; Tipo = 'aviso'; CorNome = 'ambar' }
    }
    if ($linha -match '^ladder preference: /(block|allow)bots sent$') {
        $detalhe = if ($Matches[1] -eq 'block') { 'Bloqueio de bots solicitado ao Showdown.' } else { 'Permissão para enfrentar bots solicitada ao Showdown.' }
        return [pscustomobject]@{ Titulo = 'Preferência enviada'; Detalhe = $detalhe; Tipo = 'outro'; CorNome = 'suave' }
    }
    if ($linha -notmatch 'Received pm: \|pm\|[^|]+\|~\|(.+)$') { return $null }
    $corpo = $Matches[1]
    $texto = $corpo -replace '^/error ', ''
    $detalhe = switch -Exact ($texto) {
        'You are not opted-in to playing against bots on the ladder.' { 'O bloqueio de bots já estava ativo no ladder.' }
        'You are already opted-in to playing against bots on the ladder.' { 'A permissão para enfrentar bots já estava ativa no ladder.' }
        'You have opted out of playing against bots on the ladder.' { 'O Showdown confirmou o bloqueio de bots no ladder.' }
        'You have opted in to matching against bots on the ladder.' { 'O Showdown confirmou a permissão para enfrentar bots no ladder.' }
        default { $null }
    }
    if ($detalhe) {
        return [pscustomobject]@{ Titulo = 'Preferência do ladder'; Detalhe = $detalhe; Tipo = 'outro'; CorNome = 'verde' }
    }
    if ($corpo.StartsWith('/error ')) {
        return [pscustomobject]@{ Titulo = 'Resposta do Showdown'; Detalhe = $texto; Tipo = 'aviso'; CorNome = 'ambar' }
    }
    return $null
}

# Frases curtas no lugar das linhas cruas do bot (o que não reconhece aparece como veio).
function Traduzir-Log([string[]]$linhas, [string]$filtro) {
    $saida = New-Object System.Collections.Generic.List[string]
    foreach ($l in $linhas) {
        $l = $l.TrimEnd()
        if (-not $l) { continue }
        $tipo = 'outro'
        $txt = $null
        $resposta = Ler-RespostaShowdown $l
        if ($resposta) { $txt = $resposta.Detalhe; $tipo = $resposta.Tipo }
        elseif ($l -match '^Started lor-bot@') { $txt = 'Bot iniciado' }
        elseif ($l -match "^'(.+)' laddering (\S+) at ([^:]+):") { $txt = "Preparando a conexão de $($Matches[1]) para jogar no ladder" }
        elseif ($l -match '^login confirmed: (.+)$') { $txt = "Login de $($Matches[1]) confirmado pelo Showdown" }
        elseif ($l -match '^login navegador: entre como (.+) na janela') { $txt = "Aguardando login de $($Matches[1]) na janela do Showdown" }
        elseif ($l -match '^login confirmation failed') { $txt = 'O Showdown não confirmou o login a tempo. Inicie o bot novamente.'; $tipo = 'aviso' }
        elseif ($l -match '^challenge declined by (\S+)') { $txt = "$($Matches[1]) recusou o desafio"; $tipo = 'partida' }
        elseif ($l -match '^challenge never reached (\S+)') { $txt = "O desafio não chegou a $($Matches[1]) (offline ou não aceita desafios?)"; $tipo = 'aviso' }
        elseif ($l -match '^challenge not accepted by (\S+) in (\d+) min') { $txt = "$($Matches[1]) não aceitou em $($Matches[2]) min · desafio cancelado"; $tipo = 'partida' }
        elseif ($l -match "^'(.+)' challenging (\S+) to ") { $txt = "Preparando a conexão de $($Matches[1]) para desafiar $($Matches[2])" }
        elseif ($l -match '^(Started|Finished) lor-desafio-|^lor-desafio-') { continue }
        elseif ($l -match "^'(.+)' is registered on Showdown as a bot") { $txt = "A conta $($Matches[1]) está registrada no Showdown como bot: no ladder ela só enfrenta outros bots (e quem aceitou jogar contra bots)"; $tipo = 'aviso' }
        elseif ($l -match '^waiting for our turn: team bot (\S+) is searching') { $txt = "Esperando a vez: $($Matches[1]), outro bot do time, está procurando partida pela colmeia" }
        elseif ($l -match '^waiting: known bots free, probably in the queue: (.+)') { $txt = "Esperando para procurar partida: bots que sempre aparecem estão livres na fila ($($Matches[1]))" }
        elseif ($l -eq 'team bot wait disabled: searching without a turn') { $txt = 'Espera pela colmeia desativada; buscando sem aguardar os bots do time' }
        elseif ($l -eq 'known bots wait disabled: searching now') { $txt = 'Espera por bots conhecidos desativada; seguindo para a busca de partida' }
        elseif ($l -match '^known bots still free after (\d+) min') { $txt = "Os bots conhecidos seguem livres depois de $($Matches[1]) min · procurando partida mesmo assim" }
        elseif ($l -match '^pausing ([\d.]+) min before the next ladder search') { $txt = "Pausa de $($Matches[1]) min antes de procurar a próxima partida (para não cair sempre com os mesmos bots)" }
        elseif ($l -match '^team: (\S+)') { $txt = "Time da vez: $($Matches[1])" }
        elseif ($l -match '^watch: (\S+)') { $txt = "Partida em andamento · $($Matches[1])"; $tipo = 'partida' }
        elseif ($l -match '^(win|loss|tie) vs (.+) in (\d+) turns') {
            $r = @{ win = 'Vitória'; loss = 'Derrota'; tie = 'Empate' }[$Matches[1]]
            $txt = "$r contra $($Matches[2]) em $($Matches[3]) turnos"; $tipo = 'partida'
        }
        elseif ($l -match '^(\d+)/(\d+) games won by') { $txt = "Placar desde que ligou: $($Matches[1]) de $($Matches[2]) jogos ganhos"; $tipo = 'partida' }
        elseif ($l -match '^Ctrl-C: finishing') { $txt = 'Parando depois da partida (ou série) atual' }
        elseif ($l -match '^connection to Showdown lost') { $txt = 'A conexão com o Showdown caiu · o bot vai entrar de novo'; $tipo = 'aviso' }
        elseif ($l -match '^could not connect to Showdown') { $txt = 'O Showdown não respondeu ao conectar · o bot vai tentar de novo'; $tipo = 'aviso' }
        elseif ($l -match '^reconnecting in (\d+) s') { $txt = "Reconectando em $($Matches[1]) s" }
        elseif ($l -match '^Stopping lor-bot@') { $txt = 'Desligando…' }
        elseif ($l -match '^Stopped lor-bot@') { $txt = 'Bot parado' }
        elseif ($l -match '^\s+search:|Deactivated successfully|Killing process|remains running|^lor-bot@.*Consumed|SyntaxWarning|^\s+function showErr') { continue }
        elseif ($l -match 'Showdown control message received') { continue }
        elseif ($l -match 'Private Showdown message received') { $txt = 'Mensagem privada recebida · texto em Histórico › Mensagens' }
        elseif ($l -match 'Showdown challenge received') { $txt = 'Desafio no Showdown · detalhes em Histórico › Mensagens' }
        elseif ($l -match 'Showdown notice received') { $txt = 'Aviso do Showdown · texto em Histórico › Mensagens'; $tipo = 'aviso' }
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
    Posicionar-Status
}

function Estado-Login {
    # O início mais recente invalida confirmações antigas do mesmo journal.
    for ($i = $script:logLinhas.Count - 1; $i -ge 0; $i--) {
        $linha = $script:logLinhas[$i]
        if ($linha -match '^login confirmation failed|^login navegador: autorização') { return 'falhou' }
        if ($linha -match '^login confirmed:|^ladder preference:|^watch:|^team:|^waiting for our turn:|^waiting: known bots') { return 'confirmado' }
        if ($linha -match "^Started lor-bot@|^login navegador: entre como|^reconnecting in|^'(.+)' (laddering|challenging) ") { return 'pendente' }
    }
    return ''
}

function Mostrar-Placar($e) {
    $lNos.Text = if ($e['conta']) { $e['conta'] } else { 'Sem conta' }
    $time = if ($e['time'] -eq 'top3' -or -not $e['time']) { 'Padrão' } else { $e['time'] }
    $lTimeAtivo.Text = "Time: $time"
    $lTimeAtivo.AccessibleDescription = "Time configurado: $time"
    $ttTema.SetToolTip($lNos, $lNos.Text)
    $ttTema.SetToolTip($lTimeAtivo, $lTimeAtivo.AccessibleDescription)
    $lPokemon.Text = ''
    if ($e['placar_oponente']) {
        $lRival.Text = $e['placar_oponente']
        $bo3 = $e['placar_bo3'] -eq 'sim'
        $lPlacar.Text = if ($bo3) { "$($e['placar_vitorias']) : $($e['placar_derrotas'])" } else { 'VS' }
        $lPlacarLegenda.Text = if ($bo3) { 'placar da série' } else { 'partida BO1' }
        $contexto = if ($bo3) { "BO3 · Jogo $($e['placar_jogo'])" } else { 'BO1' }
        $resultado = @{ win = 'Vitória'; loss = 'Derrota'; tie = 'Empate' }[[string]$e['placar_resultado']]
        $fase = if ($resultado) { $resultado } elseif (-not $e['placar_turno'] -or $e['placar_turno'] -eq '0') { 'Prévia de time' } else { "Turno $($e['placar_turno'])" }
        $lInfo.Text = "$contexto · $fase"
        $lPlacar.CorNome = switch ($e['placar_resultado']) { 'win' { 'verde' } 'loss' { 'vermelho' } 'tie' { 'ambar' } default { 'ouro' } }
        if ($null -ne $e['placar_nossos'] -and $e['placar_nossos'] -ne '' -and $null -ne $e['placar_deles'] -and $e['placar_deles'] -ne '') {
            $lPokemon.Text = "Pokémon: $($e['placar_nossos']) × $($e['placar_deles'])"
            $ttTema.SetToolTip($lPokemon, "Restantes · seu bot: $($e['placar_nossos']); adversário: $($e['placar_deles'])")
        }
    } else {
        $lRival.Text = 'Aguardando adversário'
        $lPlacar.Text = '—'
        $lPlacar.CorNome = 'suave'
        $lPlacarLegenda.Text = 'sem partida'
        $lInfo.Text = if ($e['bot'] -eq 'active') {
            switch (Estado-Login) {
                'pendente' { 'Conclua o login na janela do Showdown.' }
                'falhou' { 'O login não foi confirmado. Veja a atividade.' }
                default { 'Aguardando a próxima partida. Acompanhe a fila na atividade.' }
            }
        } else { 'Inicie o bot para buscar uma partida.' }
    }
    $ttTema.SetToolTip($lRival, $lRival.Text)
    $lPlacar.AccessibleName = $lPlacarLegenda.Text + ': ' + $lPlacar.Text
}

# As linhas continuam vindo do journal existente. Não há timestamps ou métricas inventados.
function Ler-Atividade([string[]]$linhas, [string]$filtro) {
    for ($i = $linhas.Count - 1; $i -ge 0; $i--) {
        $l = $linhas[$i].TrimEnd()
        $traduzida = @(Traduzir-Log @($l) $filtro)
        if ($traduzida.Count -eq 0) { continue }
        $evento = New-Object LoR.EventoAtividade
        $evento.Titulo = 'Evento do bot'
        $evento.Detalhe = $traduzida[0]
        $resposta = Ler-RespostaShowdown $l
        if ($resposta) {
            $evento.Titulo = $resposta.Titulo
            $evento.Detalhe = $resposta.Detalhe
            $evento.Tipo = $resposta.Tipo
            $evento.CorNome = $resposta.CorNome
        } elseif ($l -match '^(win|loss|tie) vs (.+) in (\d+) turns') {
            $evento.Titulo = @{ win = 'Vitória'; loss = 'Derrota'; tie = 'Empate' }[$Matches[1]]
            $evento.CorNome = @{ win = 'verde'; loss = 'vermelho'; tie = 'ambar' }[$Matches[1]]
            $evento.Detalhe = "$($Matches[2]) · $($Matches[3]) turnos"
            $evento.Tipo = 'partida'
        } elseif ($l -match '^watch: (\S+)') {
            $evento.Titulo = 'Partida em andamento'
            $evento.Detalhe = $Matches[1]
            $evento.CorNome = 'ouro'
            $evento.Tipo = 'partida'
        } elseif ($l -match '^Started lor-bot@') { $evento.Titulo = 'Bot iniciado'; $evento.Detalhe = 'Iniciando a sessão do bot.' }
        elseif ($l -match "^'(.+)' (laddering|challenging) ") { $evento.Titulo = 'Preparando conexão' }
        elseif ($l -match '^login confirmed:') { $evento.Titulo = 'Conta conectada'; $evento.CorNome = 'verde' }
        elseif ($l -match '^login navegador: entre como') { $evento.Titulo = 'Aguardando login'; $evento.CorNome = 'ambar' }
        elseif ($l -match '^login confirmation failed') { $evento.Titulo = 'Login não confirmado'; $evento.CorNome = 'ambar'; $evento.Tipo = 'aviso' }
        elseif ($l -match '^team: (\S+)') { $evento.Titulo = 'Time selecionado'; $evento.Detalhe = $Matches[1] }
        elseif ($l -match "^'(.+)' is registered on Showdown as a bot") { $evento.Titulo = 'Conta marcada como bot'; $evento.Detalhe = "$($Matches[1]): no ladder do Showdown, só enfrenta outros bots"; $evento.CorNome = 'ambar'; $evento.Tipo = 'aviso' }
        elseif ($l -match '^waiting for our turn: team bot (\S+) is searching') { $evento.Titulo = 'Esperando a vez na fila'; $evento.Detalhe = "$($Matches[1]) (do time) está procurando partida" }
        elseif ($l -match '^waiting: known bots free, probably in the queue: (.+)') { $evento.Titulo = 'Esperando bots saírem da fila'; $evento.Detalhe = $Matches[1] }
        elseif ($l -eq 'team bot wait disabled: searching without a turn') { $evento.Titulo = 'Espera pela colmeia desativada'; $evento.Detalhe = 'Buscando sem aguardar os bots do time' }
        elseif ($l -eq 'known bots wait disabled: searching now') { $evento.Titulo = 'Espera por bots desativada'; $evento.Detalhe = 'Seguindo para a busca de partida' }
        elseif ($l -match '^pausing ([\d.]+) min before') { $evento.Titulo = 'Pausa entre partidas'; $evento.Detalhe = "$($Matches[1]) min até a próxima busca" }
        elseif ($l -match '^challenge ') { $evento.Titulo = 'Desafio'; $evento.CorNome = 'ambar'; $evento.Tipo = 'partida' }
        elseif ($l -match '^connection to Showdown lost|^could not connect to Showdown') { $evento.Titulo = 'Conexão perdida'; $evento.CorNome = 'ambar'; $evento.Tipo = 'aviso' }
        elseif ($l -match '^reconnecting in') { $evento.Titulo = 'Reconectando'; $evento.CorNome = 'ambar' }
        elseif ($l -match 'Private Showdown message received') { $evento.Titulo = 'Mensagem privada'; $evento.Detalhe = 'Texto salvo em Histórico › Mensagens' }
        elseif ($l -match 'Showdown challenge received') { $evento.Titulo = 'Desafio no Showdown'; $evento.Detalhe = 'Quem e o formato em Histórico › Mensagens'; $evento.CorNome = 'ouro' }
        elseif ($l -match 'Showdown notice received') { $evento.Titulo = 'Aviso do Showdown'; $evento.Detalhe = 'Texto salvo em Histórico › Mensagens'; $evento.CorNome = 'ambar'; $evento.Tipo = 'aviso' }
        elseif ($l -match 'Traceback|Error|ERROR|WARNING|Unhandled|failed|Failed') { $evento.Titulo = 'Aviso do bot'; $evento.CorNome = 'ambar'; $evento.Tipo = 'aviso' }
        elseif ($l -match '^Ctrl-C: finishing|^Stopping lor-bot@') { $evento.Titulo = 'Parada solicitada'; $evento.CorNome = 'ambar' }
        elseif ($l -match '^Stopped lor-bot@') { $evento.Titulo = 'Bot parado' }
        $evento
    }
}

function Ler-Historico([string[]]$linhas, [string]$filtro) {
    if ($null -eq $script:historicoLinhas) {
        if ($filtro -ne 'Mensagens') { Ler-Atividade $linhas 'Partidas' }
        return
    }
    for ($i = $script:historicoLinhas.Count - 1; $i -ge 0; $i--) {
        try { $r = $script:historicoLinhas[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $evento = $null
        if ($r.kind -eq 'log') {
            if ($filtro -eq 'Mensagens') { continue }
            $itens = @(Ler-Atividade @([string]$r.text) 'Partidas')
            if ($itens.Count) { $evento = $itens[0] }
        } elseif ($r.kind -in @('chat', 'pm')) {
            if ($filtro -eq 'Partidas') { continue }
            # Controles do Showdown podem chegar como chat e existir no historico antigo.
            if ([string]$r.sender -notmatch '[a-z0-9]' -or $r.text -isnot [string] -or -not $r.text) { continue }
            if ($r.text -match '^/(?:uhtmlchange|uhtml|raw|html|challenge)(?:\s|$)') { continue }
            $evento = New-Object LoR.EventoAtividade
            $origem = if ($r.kind -eq 'pm') { 'PM recebida' } elseif ($r.own) { 'Seu bot' } else { 'Oponente' }
            $evento.Titulo = "$origem · $($r.sender)"
            $evento.Detalhe = [string]$r.text
            if ($r.room) { $evento.Detalhe += "`r`nSala: $($r.room)" }
            $evento.Tipo = 'mensagem'
        } elseif ($r.kind -in @('desafio', 'aviso')) {
            if ($filtro -eq 'Partidas') { continue }
            if ($r.sender -isnot [string] -or $r.text -isnot [string] -or -not $r.text) { continue }
            $evento = New-Object LoR.EventoAtividade
            if ($r.kind -eq 'desafio') {
                $evento.Titulo = if ($r.own) { "Desafio enviado · para $($r.to)" } else { "Desafio recebido · $($r.sender)" }
                $evento.Detalhe = "Formato: $($r.text)"
                $evento.CorNome = 'ouro'
            } else {
                $evento.Titulo = "Aviso do Showdown · $($r.sender)"
                $evento.Detalhe = [string]$r.text
                $evento.CorNome = 'ambar'
            }
            $evento.Tipo = 'mensagem'
        }
        if ($evento) {
            try {
                $hora = [DateTimeOffset]::Parse([string]$r.time).ToLocalTime().ToString('dd/MM HH:mm:ss')
                $evento.Titulo = "$hora · $($evento.Titulo)"
            } catch { }
            $evento
        }
    }
}

function Atualizar-Atividade {
    # O log veio junto com o estado; só sem ele (resposta antiga) pede à parte.
    $linhas = if ($null -ne $script:logLinhas) { $script:logLinhas } else { (Invoke-Painel @('log', '80')).Saida -split "`n" }
    $eventos = @(Ler-Atividade $linhas $cFiltro.Escolhido | Select-Object -First 4)
    $atividade.Definir([LoR.EventoAtividade[]]$eventos)
    $recentes = @(Ler-Historico $linhas $cFiltroHistorico.Escolhido)
    $atividadeHistorico.Definir([LoR.EventoAtividade[]]$recentes)
    $texto = $linhas -join "`r`n"
    if ($tLog.Caixa.Text -ne $texto) {
        $tLog.Caixa.Text = $texto
        $tLog.Caixa.SelectionStart = $tLog.Caixa.Text.Length
        $tLog.Caixa.ScrollToCaret()
    }
}

# "Hoje: 7V–4D · MC371 4-2, MC196 3-2" (vazio antes da primeira partida do dia).
function Texto-Hoje($e) {
    $v = [int]('0' + $e['hoje_vitorias']); $d = [int]('0' + $e['hoje_derrotas'])
    if ($v + $d -eq 0) { return '' }
    $t = "Hoje: ${v}V–${d}D"
    if ($e['hoje_times']) { $t += " · $($e['hoje_times'])" }
    $t
}

function Atualizar-EstadoTela($Resposta = $null) {
    $e = Ler-Estado $Resposta
    # Se o WSL não respondeu na abertura, os seletores ainda estão no padrão: carrega antes de
    # reabilitar o Aplicar, senão ele gravaria BO3/Padrão por cima da configuração salva.
    if (-not $script:opcoesCarregadas) { Carregar-Opcoes }
    $script:estado = $e
    $bot = $e['bot']
    $ligado = $bot -in @('active', 'activating')
    $bo3 = if ($e['placar_oponente']) { $e['placar_bo3'] -eq 'sim' } else { $e['formato'] -ne 'bo1' }
    $titulos = @{ active = 'Bot em execução'; activating = 'Ligando…'; deactivating = 'Parando após a partida'; inactive = 'Bot parado'; failed = 'Bot parou com erro' }
    $lBot.Text = if ($titulos[$bot]) { $titulos[$bot] } else { "Bot: $bot" }
    if ($bot -eq 'deactivating' -and $bo3) { $lBot.Text = 'Parando ao fim da série' }
    $desafio = $e['desafio']
    if ($desafio -and $bot -eq 'deactivating' -and $e['desafio_fase'] -eq 'esperando') { $lBot.Text = 'Trocando para o desafio' }
    $pBot.CorNome = switch ($bot) { 'active' { 'ponto' } 'failed' { 'vermelho' } { $_ -in 'activating', 'deactivating' } { 'ambar' } default { 'desligado' } }
    $pBot.Invalidate()
    if ($e['partida']) {
        $selo.Tipo = 'verde'
        $selo.Text = if ($desafio -and $e['desafio_fase'] -eq 'jogando') { "Desafio contra $desafio" } else { 'Partida em andamento' }
        $selo.Visible = $true
    } elseif ($desafio) {
        $fases = @{ esperando = "Desafio a $desafio depois da partida"; aguardando = "Esperando $desafio aceitar"; jogando = "Desafio contra $desafio"; cancelando = 'Cancelando o desafio' }
        $selo.Tipo = if ($e['desafio_fase'] -eq 'aguardando') { 'neutra' } else { 'ambar' }
        $selo.Text = if ($fases[$e['desafio_fase']]) { $fases[$e['desafio_fase']] } else { "Desafio a $desafio" }
        $selo.Visible = $true
    } elseif ($bot -eq 'active') {
        $faseLogin = Estado-Login
        $selo.Tipo = if ($faseLogin -in @('pendente', 'falhou')) { 'ambar' } else { 'neutra' }
        $selo.Text = switch ($faseLogin) { 'pendente' { 'Aguardando login' } 'falhou' { 'Login não confirmado' } default { 'Aguardando partida' } }
        $selo.Visible = $true
    }
    elseif ($bot -eq 'failed') { $selo.Tipo = 'ambar'; $selo.Text = 'Veja a atividade'; $selo.Visible = $true }
    else { $selo.Visible = $false }
    $ttTema.SetToolTip($selo, $selo.Text)
    $chip.Visible = [bool]$e['memoria_mb']
    $chip.Text = "$($e['memoria_mb']) MB"
    $pElo.Visible = [bool]$e['elo']
    if ($e['elo']) {
        $pElo.Text = "Elo $($e['elo'])"
        $dica = "Elo no ladder oficial ($(([string]$e['formato']).ToUpper()))"
        if ($e['elo_gxe']) { $dica += " · GXE $(([string]$e['elo_gxe']).Replace('.', ','))%" }
        if ($e['elo_partidas']) { $dica += " · $($e['elo_partidas']) partidas" }
        $ttTema.SetToolTip($pElo, $dica)
        $pElo.AccessibleName = $dica
    }
    Arrumar-Status
    Mostrar-Placar $e
    $lVersao.Text = "Versão $($e['versao'])"
    if (Precisa-Atualizar) { $lAtualizar.Text = "Atualizar para $($script:versaoNova)"; $lAtualizar.Negrito = $true }
    else { $lAtualizar.Text = 'Verificar atualização'; $lAtualizar.Negrito = $false }
    if (-not $tUsuario.Caixa.Focused -and -not $tUsuario.Caixa.Modified) { $tUsuario.Caixa.Text = $e['conta'] }
    $lNavConta.Text = if ($e['conta']) { $e['conta'] } else { 'Sem conta' }
    $ttTema.SetToolTip($lNavConta, $lNavConta.Text)
    $configurada = [bool]$e['conta']
    $lNavEstado.Text = if ($configurada) { 'Conta configurada' } else { 'Configure em Ajustes' }
    $modoLogin = if ($e['login'] -eq 'senha') { 'login legado' } else { 'login no navegador' }
    $lResumoConta.Text = if ($configurada) { "$($e['conta']) · $modoLogin" } else { 'Configure o usuário do Showdown' }
    $ttTema.SetToolTip($lResumoConta, $lResumoConta.Text)
    if ($e['codigo'] -eq 'sim') {
        $tCodigo.Dica = 'Código salvo (cole outro para trocar)'
        $pCodigo.CorNome = 'ponto'
        $lCodigo.CorNome = 'verde'
        $lCodigo.Text = if ($e['envio'] -eq 'active') { 'Salvo · enviando as partidas' } else { 'Salvo · o envio liga junto com o bot' }
        $lResumoColeta.Text = if ($e['envio'] -eq 'active') { 'Código salvo · envio ativo' } else { 'Código salvo · envio aguardando' }
        $lResumoColeta.CorNome = if ($e['envio'] -eq 'active') { 'verde' } else { 'suave' }
        # O que a coleta respondeu de fato no último envio (o serviço ativo não garante que chega).
        if ($e['envio'] -eq 'active' -and $e['envio_status'] -eq 'codigo') {
            $pCodigo.CorNome = 'vermelho'
            $lCodigo.CorNome = 'vermelho'
            $lCodigo.Text = 'Código recusado pela coleta: peça outro ao Thiago'
            $lResumoColeta.Text = 'Código recusado pela coleta'
            $lResumoColeta.CorNome = 'vermelho'
        } elseif ($e['envio'] -eq 'active' -and $e['envio_status'] -eq 'fora') {
            $lCodigo.CorNome = 'ambar'
            $lCodigo.Text = 'Salvo · coleta fora do ar, envia quando voltar'
            $lResumoColeta.Text = 'Código salvo · coleta fora do ar'
            $lResumoColeta.CorNome = 'ambar'
        }
    } else {
        $tCodigo.Dica = 'Cole seu código'
        $pCodigo.CorNome = 'ambar'
        $lCodigo.CorNome = 'ambar'
        $lCodigo.Text = 'Não salvo · sem um código válido o bot não liga'
        $lResumoColeta.Text = 'Código não configurado'
        $lResumoColeta.CorNome = 'ambar'
    }
    $pCodigo.Invalidate()
    if (-not $script:recolhido -or $script:secao -eq 'historico') { Atualizar-Atividade }
    $bLigar.Enabled = -not $ligado -and $bot -ne 'deactivating'
    $mostrarLigar = $bot -notin @('active', 'activating', 'deactivating')
    $bLigar.Visible = $mostrarLigar
    $bVer.Visible = -not $mostrarLigar
    $bDesligar.Enabled = $ligado
    $bDesligar.Text = if ($bo3) { 'Parar ao fim da série' } else { 'Parar após a partida' }
    $bAgora.Enabled = $bot -in @('active', 'activating', 'deactivating')
    $bVer.Enabled = [bool]$e['partida']
    $bDesafiar.Text = if ($desafio) { 'Cancelar desafio' } else { 'Desafiar jogador' }
    foreach ($c in @($bAplicar, $bConta, $bCodigo, $xDiscord, $xChat, $xBloquearBots, $xEsperarBots, $xEsperarColmeia, $xDecisoesInstantaneas, $bDesafiar)) { $c.Enabled = $true }
    $script:resumoHoje = Texto-Hoje $e
    if ($script:secao -eq 'historico') {
        $lSubtitulo.Text = if ($script:resumoHoje) { $script:resumoHoje } else { 'Resultados, mensagens, replays e arquivos locais.' }
    }
    Avisar-Bandeja $bot
}

# Ícone na bandeja do Windows (criado no fim do arquivo, junto do timer): o resumo no tooltip e um
# aviso quando o bot para com erro, para quem deixou o bot jogando e foi fazer outra coisa.
function Avisar-Bandeja([string]$bot) {
    if (-not $script:bandeja) { return }
    $texto = "LoR Bots: $($lBot.Text)"
    if ($script:resumoHoje) { $texto += " · $($script:resumoHoje -replace '^Hoje: ', '')" }
    $script:bandeja.Text = if ($texto.Length -gt 63) { $texto.Substring(0, 62) + '…' } else { $texto }
    if ($bot -eq 'failed' -and $script:botAnterior -and $script:botAnterior -ne 'failed') {
        $script:bandeja.ShowBalloonTip(15000, 'LoR Bots: o bot parou com erro',
            'Abra o painel e veja a atividade. Se precisar de ajuda, use "Copiar diagnóstico" no ícone da bandeja.', 'Warning')
    }
    $script:botAnterior = $bot
}

function Copiar-Diagnostico {
    $r = Invoke-Painel @('diagnostico')
    $texto = "Painel $(Versao-Painel) · Windows $([Environment]::OSVersion.Version)`r`n" + (($r.Saida + "`n" + $r.Erro).Trim() -replace "`r?`n", "`r`n")
    try {
        [System.Windows.Forms.Clipboard]::SetText($texto)
        Mensagem 'Diagnóstico copiado (versão, estado e logs, sem senha nem código). Cole no Discord com Ctrl+V para quem for ajudar.'
    } catch { Mensagem "Não consegui copiar: $($_.Exception.Message)" }
}

# A consulta do timer roda em segundo plano: o wsl.exe às vezes leva segundos (WSL acordando, PC
# ocupado) e a janela não pode congelar enquanto isso. O mesmo que o Invoke-Painel faz.
$ConsultaEstado = {
    param($distro, $controle)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = "-d $distro -u root -e /opt/lor-bots/painel.sh estado --log 80"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    Invoke-ProcessoPainel $psi -Controle $controle
}
$script:pedido = $null

function Encerrar-ConsultaEstado {
    if (-not $script:pedido) { return }
    $pedido = $script:pedido
    $script:pedido = $null
    $pedido.Controle.Cancelar = $true
    try { [void]$pedido.PS.EndInvoke($pedido.Handle) } finally { $pedido.PS.Dispose() }
}

# Um passo do timer: pede o estado em segundo plano, ou mostra a resposta que chegou.
function Atualizar-EmSegundoPlano {
    if (-not $script:pedido) {
        $ps = [PowerShell]::Create()
        $controle = [hashtable]::Synchronized(@{ Cancelar = $false })
        [void]$ps.AddScript('function Invoke-ProcessoPainel {' + ${function:Invoke-ProcessoPainel}.ToString() + '}')
        [void]$ps.AddScript($ConsultaEstado.ToString()).AddArgument($Distro).AddArgument($controle)
        try { $script:pedido = @{ PS = $ps; Controle = $controle; Handle = $ps.BeginInvoke() } }
        catch { $ps.Dispose(); throw }
        return
    }
    if (-not $script:pedido.Handle.IsCompleted) { return }
    $pedido = $script:pedido
    $script:pedido = $null
    try {
        $r = @($pedido.PS.EndInvoke($pedido.Handle))[0]
        if (-not $r) { throw 'O WSL não respondeu.' }
        Atualizar-EstadoTela $r
    } catch {
        Mostrar-Falha $_.Exception.Message
    } finally { $pedido.PS.Dispose() }
}

function Mostrar-Falha([string]$erro) {
    $script:estado = @{}
    $lBot.Text = 'Sem resposta do WSL'
    Mostrar-Placar @{}
    $lInfo.Text = 'Verifique o WSL. Tentando novamente…'
    $ttTema.SetToolTip($lInfo, $erro)
    $pBot.CorNome = 'vermelho'
    $pBot.Invalidate()
    $chip.Visible = $false
    $pElo.Visible = $false
    $selo.Visible = $false
    foreach ($c in @($bLigar, $bVer, $bDesligar, $bAgora, $bAplicar, $bConta, $bCodigo, $xDiscord, $xChat, $xBloquearBots, $xEsperarBots, $xEsperarColmeia, $xDecisoesInstantaneas, $bDesafiar)) { $c.Enabled = $false }
    Arrumar-Status
}

function Atualizar-Tela {
    try { Atualizar-EstadoTela } catch { Mostrar-Falha $_.Exception.Message }
}


function Carregar-Opcoes {
    $e = Ler-Estado
    $cFormato.Indice = if ($e['formato'] -eq 'bo1') { 1 } else { 0 }
    $cTimer.Indice = if ($e['timer'] -eq 'nao') { 1 } else { 0 }
    $xDiscord.Marcado = $e['discord'] -ne 'nao'
    $xChat.Marcado = $e['chat'] -ne 'nao'
    $xBloquearBots.Marcado = $e['bloquear_bots'] -ne 'nao'
    $xEsperarBots.Marcado = $e['esperar_bots'] -ne 'nao'
    $xEsperarColmeia.Marcado = $e['esperar_colmeia'] -ne 'nao'
    $xDecisoesInstantaneas.Marcado = $e['decisoes_instantaneas'] -eq 'sim'
    Atualizar-RotuloDecisoes
    $cTime.Itens.Clear()
    $cTime.Itens.Add('Padrão (MC371/MC196)')
    foreach ($t in ((Invoke-Painel @('times')).Saida -split "`n")) { if ($t.Trim()) { $cTime.Itens.Add($t.Trim()) } }
    $i = if ($e['time'] -and $e['time'] -ne 'top3') { $cTime.Itens.IndexOf($e['time']) } else { 0 }
    $cTime.Indice = [Math]::Max(0, $i)
    $script:opcoesCarregadas = $true
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
    $r = Invoke-Painel @('conta-navegador') ("$($tUsuario.Caixa.Text.Trim())`n")
    $tUsuario.Caixa.Modified = $false
    if (Resultado $r '') {
        if ($script:estado['bot'] -eq 'active') {
            Invoke-Painel @('reiniciar') | Out-Null
            Manter-Vivo
            Mensagem 'Conta salva. O bot entra com ela depois da partida atual.'
        } else { Mensagem 'Conta salva.' }
    }
    Atualizar-Tela
})

$bCodigo.Add_Click({
    if (-not $tCodigo.Caixa.Text.Trim()) { Mensagem 'Cole o código que o Thiago passou.'; return }
    $r = Invoke-Painel @('codigo') ($tCodigo.Caixa.Text.Trim() + "`n")
    if (Resultado $r '') {
        $tCodigo.Caixa.Text = ''
        # A coleta confere o código antes de salvar e diz de quem ele é.
        if ($r.Saida -match '(?m)^aviso=(.+)$') { Mensagem "Código salvo, mas $($Matches[1].Trim())." }
        elseif ($r.Saida -match '(?m)^membro=(.+)$') { Mensagem "Código de $($Matches[1].Trim()) conferido e salvo. As partidas deste bot vão para a coleta do time." }
        else { Mensagem 'Código salvo. As partidas deste bot vão para a coleta do time.' }
    }
    Atualizar-Tela
})

# Vale já para a próxima partida enviada à coleta, sem reiniciar o bot.
function Mudar-Discord {
    $v = if ($xDiscord.Marcado) { 'sim' } else { 'nao' }
    if (Resultado (Invoke-Painel @('discord', $v)) '') {
        if ($xDiscord.Marcado) { Mensagem 'As próximas partidas deste PC voltam a ser postadas no Discord.' }
        else { Mensagem 'As próximas partidas deste PC não serão postadas no Discord. Elas continuam indo para o treino do time.' }
    } else { $xDiscord.Marcado = -not $xDiscord.Marcado }
}
$xDiscord.add_Mudou({ Mudar-Discord })
$lDiscord.Add_Click({ if ($xDiscord.Enabled) { $xDiscord.Marcado = -not $xDiscord.Marcado; Mudar-Discord } })

# Vale já na próxima partida, sem reiniciar o bot.
function Mudar-Chat {
    $v = if ($xChat.Marcado) { 'sim' } else { 'nao' }
    if (Resultado (Invoke-Painel @('chat', $v)) '') {
        if ($xChat.Marcado) { Mensagem 'A partir da próxima partida, o bot usa as saudações da sua personalidade no começo e no fim.' }
        else { Mensagem 'A partir da próxima partida, o bot não manda mais nada no chat.' }
    } else { $xChat.Marcado = -not $xChat.Marcado }
}
$xChat.add_Mudou({ Mudar-Chat })
$lChat.Add_Click({ if ($xChat.Enabled) { $xChat.Marcado = -not $xChat.Marcado; Mudar-Chat } })

function Mudar-BloquearBots {
    $v = if ($xBloquearBots.Marcado) { 'sim' } else { 'nao' }
    if (Resultado (Invoke-Painel @('bloquear-bots', $v)) '') {
        $comando = if ($xBloquearBots.Marcado) { '/blockbots' } else { '/allowbots' }
        Mensagem "Preferência salva. O bot envia $comando no próximo login ou antes da próxima busca por partida."
    } else { $xBloquearBots.Marcado = -not $xBloquearBots.Marcado }
}
$xBloquearBots.add_Mudou({ Mudar-BloquearBots })
$lBloquearBots.Add_Click({ if ($xBloquearBots.Enabled) { $xBloquearBots.Marcado = -not $xBloquearBots.Marcado; Mudar-BloquearBots } })

function Mudar-EsperarBots {
    $v = if ($xEsperarBots.Marcado) { 'sim' } else { 'nao' }
    if (Resultado (Invoke-Painel @('esperar-bots', $v)) '') {
        if ($xEsperarBots.Marcado) { Mensagem 'Preferência salva. Antes da próxima busca, o bot espera até 10 minutos por bots adversários conhecidos saírem da fila.' }
        else { Mensagem 'Preferência salva. O bot pula a espera por bots adversários conhecidos, inclusive uma espera em curso. A coordenação do nosso time e a pausa entre partidas continuam iguais.' }
    } else { $xEsperarBots.Marcado = -not $xEsperarBots.Marcado }
}
$xEsperarBots.add_Mudou({ Mudar-EsperarBots })
$lEsperarBots.Add_Click({ if ($xEsperarBots.Enabled) { $xEsperarBots.Marcado = -not $xEsperarBots.Marcado; Mudar-EsperarBots } })

function Mudar-EsperarColmeia {
    $v = if ($xEsperarColmeia.Marcado) { 'sim' } else { 'nao' }
    if (Resultado (Invoke-Painel @('esperar-colmeia', $v)) '') {
        if ($xEsperarColmeia.Marcado) { Mensagem 'Preferência salva. Na próxima busca, o bot espera a vez entre os bots da nossa colmeia.' }
        else { Mensagem 'Preferência salva. O bot deixa de esperar pelos bots da nossa colmeia e libera a vez reservada. A espera por adversários conhecidos segue sua própria opção.' }
    } else { $xEsperarColmeia.Marcado = -not $xEsperarColmeia.Marcado }
}
$xEsperarColmeia.add_Mudou({ Mudar-EsperarColmeia })
$lEsperarColmeia.Add_Click({ if ($xEsperarColmeia.Enabled) { $xEsperarColmeia.Marcado = -not $xEsperarColmeia.Marcado; Mudar-EsperarColmeia } })

function Atualizar-RotuloDecisoes {
    $lDecisoesValor.Text = if ($xDecisoesInstantaneas.Marcado) { 'Sim' } else { 'Não' }
    $xDecisoesInstantaneas.AccessibleName = "Decisões Instantâneas: $($lDecisoesValor.Text)"
}
function Mudar-DecisoesInstantaneas {
    $v = if ($xDecisoesInstantaneas.Marcado) { 'sim' } else { 'nao' }
    if (Resultado (Invoke-Painel @('decisoes-instantaneas', $v)) '') {
        if ($xDecisoesInstantaneas.Marcado) { Mensagem 'Decisões Instantâneas: Sim. O bot envia assim que termina o cálculo, encerrando também uma espera adicional em curso.' }
        else { Mensagem 'Decisões Instantâneas: Não. As próximas decisões seguem o ritmo da personalidade, contando o cálculo. A escolha de Pokémon leva mais tempo; trocas forçadas, menos. Com pouco tempo no relógio, o bot reduz a espera.' }
    } else { $xDecisoesInstantaneas.Marcado = -not $xDecisoesInstantaneas.Marcado }
    Atualizar-RotuloDecisoes
}
$xDecisoesInstantaneas.add_Mudou({ Mudar-DecisoesInstantaneas })
foreach ($c in @($lDecisoesInstantaneas, $lDecisoesValor)) {
    $c.Add_Click({ if ($xDecisoesInstantaneas.Enabled) { $xDecisoesInstantaneas.Marcado = -not $xDecisoesInstantaneas.Marcado; Mudar-DecisoesInstantaneas } })
}

$bAplicar.Add_Click({
    $f = if ($cFormato.Indice -eq 1) { 'bo1' } else { 'bo3' }
    $t = if ($cTime.Indice -le 0) { 'top3' } else { $cTime.Escolhido }
    $tm = if ($cTimer.Indice -eq 1) { 'nao' } else { 'sim' }
    if (-not (Resultado (Invoke-Painel @('formato', $f)) '')) { return }
    if (-not (Resultado (Invoke-Painel @('timer', $tm)) '')) { return }
    if (-not (Resultado (Invoke-Painel @('time', $t)) '')) { return }
    $r = Invoke-Painel @('reiniciar')
    if (-not (Resultado $r '')) { return }
    $lConfigStatus.CorNome = 'ouro'
    $lConfigStatus.Text = if ($r.Saida -match 'reiniciando') { 'Salvo · entra após a partida ou série.' }
        elseif ($r.Saida -match 'depois-do-desafio') { 'Salvo · entra ao voltar ao ladder.' }
        else { 'Salvo · pronto para iniciar o bot.' }
    if ($r.Saida -match 'reiniciando') { Mensagem 'Salvo. O bot reinicia com isso depois da partida (ou série) atual.' }
    elseif ($r.Saida -match 'depois-do-desafio') { Mensagem 'Salvo. Vale quando o bot voltar do desafio.' }
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
    if (-not (Confirmar "Remover o time $t?")) { return }
    [void](Resultado (Invoke-Painel @('remover-time', $t)) '')
    Carregar-Opcoes
    Atualizar-Tela
})

$bDesafiar.Add_Click({
    Atualizar-Tela
    $alvo = $script:estado['desafio']
    if ($alvo) {
        if (-not (Confirmar "Cancelar o desafio a $alvo? Se a partida já começou, o bot termina ela antes.")) { return }
        [void](Resultado (Invoke-Painel @('cancelar-desafio')) '')
        Atualizar-Tela
        return
    }
    if (-not $script:estado['conta']) { Mensagem 'Salve a conta do bot primeiro.'; return }
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Desafiar jogador'
    $d.AutoScaleMode = 'None'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ClientSize = New-Object System.Drawing.Size((S 480), (S 300))
    $d.StartPosition = 'CenterParent'
    $d.BackColor = [LoR.Tema]::Atual.Fundo
    $d.Font = $form.Font
    [LoR.Janela]::TituloEscuro($d)
    $r1 = Novo-Rotulo 'Usuário do Showdown' 20 16 300 22 $d
    $r1.FundoNome = 'fundo'
    $tAlvo = Novo-Campo 'ex.: Sier' 20 42 300 36 $d
    $tAlvo.FundoNome = 'fundo'
    $r2 = Novo-Rotulo 'Partidas' 340 16 120 22 $d
    $r2.FundoNome = 'fundo'
    $cPartidas = Nova-Lista @('1', '2', '3', '5', '10') 340 42 120 36 $d
    $cPartidas.FundoNome = 'fundo'
    $formato = ([string]$script:estado['formato']).ToUpper()
    $ajuda = "No formato e com o time escolhidos ($formato). Se o bot estiver no ladder, ele termina a partida " +
        "(ou série) atual, desafia, e volta ao ladder no fim. Se ninguém aceitar em 5 minutos, o desafio é cancelado."
    $r3 = Novo-Rotulo $ajuda 20 96 440 120 $d 'suave' 10
    $r3.FundoNome = 'fundo'
    $r3.Alinhar = [System.Windows.Forms.TextFormatFlags]'WordBreak'
    $bOk = Novo-Botao 'Desafiar' 'Primario' '' 252 240 100 38 $d
    $bOk.FundoNome = 'fundo'
    $bCancelar = Novo-Botao 'Cancelar' 'Neutro' '' 360 240 100 38 $d
    $bCancelar.FundoNome = 'fundo'
    $bCancelar.Add_Click({ $d.Close() })
    $bOk.Add_Click({
        if (-not $tAlvo.Caixa.Text.Trim()) { Mensagem 'Coloque o usuário do Showdown.'; return }
        $r = Invoke-Painel @('desafiar', $cPartidas.Escolhido) ($tAlvo.Caixa.Text.Trim() + "`n")
        if (Resultado $r 'Desafio agendado. Peça para a pessoa aceitar no Showdown quando chegar.') {
            Manter-Vivo
            $d.Close()
        }
    })
    [void]$d.ShowDialog($form)
    Atualizar-Tela
})

$bLigar.Add_Click({
    $r = Invoke-Painel @('ligar')
    if (Resultado $r '') {
        Manter-Vivo
        if ($r.Saida -match 'depois-do-desafio') { Mensagem 'O bot está num desafio. O ladder liga quando ele acabar.' }
    }
    Atualizar-Tela
})
$bDesligar.Add_Click({ [void](Resultado (Invoke-Painel @('desligar')) ''); Atualizar-Tela })
$bAgora.Add_Click({
    if (-not (Confirmar 'Parar agora? A partida em andamento fica pela metade (o bot perde por W.O.).')) { return }
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
$bReplays.Add_Click({ $bHistorico.PerformClick() })
$bPastaPartidas.Add_Click({ Start-Process explorer.exe "\\wsl$\$Distro\opt\lor-bots\ai-vgc\data\live_games" })

$cFiltro.add_Escolheu({ $tLog.Caixa.Text = ''; Atualizar-Tela })
$cFiltroHistorico.add_Escolheu({ Atualizar-Atividade })
$bRecolher.Add_Click({
    $script:recolhido = -not $script:recolhido
    Arrumar-Atividade
    if (-not $script:recolhido) { Atualizar-Tela }
})
$bTecnico.Add_Click({ $script:logTecnico = -not $script:logTecnico; Arrumar-Atividade })

function Mudar-Auto {
    if ($xAuto.Marcado) {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($Atalho)
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $s.Arguments = "`"$Lancador`" -Ligar"
        $s.WorkingDirectory = $Pasta
        $s.IconLocation = $IconeAtalho
        $s.Save()
    } elseif (Test-Path $Atalho) { Remove-Item $Atalho }
}
$xAuto.add_Mudou({ Mudar-Auto })
$lAuto.Add_Click({ $xAuto.Marcado = -not $xAuto.Marcado; Mudar-Auto })

function Versao-Painel {
    try { (Get-Content $ArquivoVersao -TotalCount 1).Trim() } catch { '' }
}

# Versão nova no GitHub para o Linux ou para este painel (cada um pode ter ficado para trás).
function Precisa-Atualizar {
    [bool]$script:versaoNova -and ($script:versaoNova -ne $script:estado['versao'] -or $script:versaoNova -ne (Versao-Painel))
}

function Consultar-Atualizacao {
    $script:versaoNova = $null
    $script:atualizacao = $null
    $ramoUrl = [Uri]::EscapeDataString($Ramo)
    $commit = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri "https://api.github.com/repos/sierrific/lake-of-rage-battle-bots/commits/$ramoUrl").Content | ConvertFrom-Json
    if ($commit.sha -cnotmatch '^[0-9a-f]{40}$') { throw 'O GitHub não informou uma revisão válida.' }
    $rawFixo = "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$($commit.sha)"
    $versao = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri "$rawFixo/VERSION").Content.Trim()
    if ($versao -cnotmatch '^[A-Za-z0-9._-]+$') { throw 'O GitHub não informou uma versão válida.' }
    $script:atualizacao = [pscustomobject]@{ Sha = $commit.sha; Versao = $versao; Raw = $rawFixo }
    $script:versaoNova = $versao
}

function Comando-Atualizacao($versao) {
    # Também atualiza instalações cujo updater antigo ainda não entende LOR_REVISION.
    # Baixa o script inteiro para um temporário antes de executar, sempre do mesmo commit.
    $bash = @'
set -euo pipefail
script=$(mktemp)
trap 'rm -f "$script"' EXIT
curl -fsSL --max-time 30 'https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/{0}/linux/atualizar.sh' -o "$script"
LOR_REVISION='{0}' LOR_VERSION='{1}' bash "$script"
'@ -f $versao.Sha, $versao.Versao
    $codificado = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash.Replace("`r", '')))
    "-d $Distro -u root -e bash -c `"echo $codificado | base64 -d | bash`""
}

function Atualizar-Painel {
    $versao = $script:atualizacao
    if (-not $versao) { Mensagem 'Consulte a versão no GitHub antes de atualizar.'; return }
    if (-not (Confirmar "Baixar a versão $($script:versaoNova) do bot e do painel? Se o bot estiver jogando, ele termina a partida atual antes de reiniciar.")) { return }
    # O painel novo só entra no lugar deste depois que a atualização do Linux deu certo; antes disso
    # fica ao lado (Painel.novo.ps1), e o atual vira Painel.anterior.ps1 (para voltar à mão, se precisar).
    $atual = Join-Path $Pasta 'Painel.ps1'
    $novo = Join-Path $Pasta 'Painel.novo.ps1'
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$($versao.Raw)/windows/Painel.ps1" -OutFile $novo
        $erros = $null
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content $novo -Raw -Encoding UTF8), [ref]$erros)
        if ($erros.Count -gt 0) { throw 'o painel baixado veio incompleto ou com erro. Tente de novo.' }
    } catch {
        Remove-Item $novo -ErrorAction SilentlyContinue
        Mensagem "Não consegui baixar a versão nova: $($_.Exception.Message)"
        return
    }
    # O Linux numa janela que mostra o progresso; o código de saída diz se deu certo.
    $p = Start-Process wsl.exe -PassThru -ArgumentList (Comando-Atualizacao $versao)
    [void]$p.Handle  # guarda o processo, senão o ExitCode volta vazio
    # Espera sem congelar a janela (a atualização leva minutos): o timer fica parado e os botões
    # desligados até ela terminar.
    $timer.Stop()
    Encerrar-ConsultaEstado
    foreach ($c in @($bLigar, $bVer, $bDesligar, $bAgora, $bAplicar, $bConta, $bCodigo, $xDiscord, $xChat, $xBloquearBots, $xEsperarBots, $xEsperarColmeia, $xDecisoesInstantaneas, $bDesafiar)) { $c.Enabled = $false }
    $lAtualizar.Text = 'Atualizando… (veja a janela de progresso)'
    $lAtualizar.Enabled = $false
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    $lAtualizar.Enabled = $true
    $timer.Start()
    $codigo = $p.ExitCode
    $p.Dispose()
    if ($codigo -ne 0) {
        Remove-Item $novo -ErrorAction SilentlyContinue
        Mensagem ("A atualização do bot parou no meio (código $codigo). O painel continua nesta versão, e o bot " +
            "segue como estava. Tente Atualizar de novo; se falhar outra vez, mande um print da janela de progresso.")
        Manter-Vivo
        Atualizar-Tela
        return
    }
    try {
        Copy-Item -Force $atual (Join-Path $Pasta 'Painel.anterior.ps1')
        Move-Item -Force $novo $atual
        Set-Content -Path $ArquivoVersao -Value $versao.Versao -Encoding ASCII
        Set-Content -Path (Join-Path $Pasta 'REVISION') -Value $versao.Sha -Encoding ASCII
    } catch {
        Remove-Item $novo -ErrorAction SilentlyContinue
        Mensagem ("O bot foi atualizado, mas não consegui trocar o painel ($($_.Exception.Message)). Pode ser pouco " +
            "espaço no disco C: ou o arquivo aberto em outro programa. Libere espaço e clique em Atualizar de novo: o " +
            "painel termina a troca (o bot não é reinstalado de novo).")
        Manter-Vivo
        Atualizar-Tela
        return
    }
    Manter-Vivo
    $trava.ReleaseMutex()
    Start-Process wscript.exe -ArgumentList "`"$Lancador`""
    $form.Close()
}
$lAtualizar.Add_Click({
    try { Consultar-Atualizacao } catch { }
    if (Precisa-Atualizar) { Atualizar-Painel }
    elseif ($script:versaoNova) { Mensagem "Já está na versão mais nova ($($script:versaoNova))." }
    else { Mensagem 'Não consegui ver a versão no GitHub. Confira a internet e tente de novo.' }
    Atualizar-Tela
})

$timer = New-Object System.Windows.Forms.Timer
# Um passo pede e o seguinte mostra: a tela se renova a cada ~5 s, sem esperar o WSL.
$timer.Interval = 2500
$timer.Add_Tick({
    try { Atualizar-EmSegundoPlano } catch { Mostrar-Falha $_.Exception.Message }
})

$script:bandeja = New-Object System.Windows.Forms.NotifyIcon
$script:bandeja.Icon = [System.Drawing.SystemIcons]::Application
if ($form.Icon) {
    # Na bandeja o Windows quer o quadro pequeno (16 px a 100%); pedir o tamanho certo evita
    # reduzir o de 32 px e borrar o pixel art.
    try { $script:bandeja.Icon = New-Object System.Drawing.Icon($form.Icon, [System.Windows.Forms.SystemInformation]::SmallIconSize) }
    catch { $script:bandeja.Icon = $form.Icon }
}
$script:bandeja.Text = 'Painel LoR Bots'
$menuBandeja = New-Object System.Windows.Forms.ContextMenuStrip
$abrirPainel = { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
[void]$menuBandeja.Items.Add('Abrir o painel', $null, $abrirPainel)
[void]$menuBandeja.Items.Add('Copiar diagnóstico', $null, { Copiar-Diagnostico })
$script:bandeja.ContextMenuStrip = $menuBandeja
$script:bandeja.Add_DoubleClick($abrirPainel)
$script:bandeja.Add_BalloonTipClicked($abrirPainel)
$script:bandeja.Visible = $true

$form.Add_Shown({
    $form.Cursor = 'WaitCursor'
    # A primeira chamada liga o Linux do WSL e leva alguns segundos.
    $pBot.CorNome = 'ambar'
    $form.Refresh()
    try {
        Carregar-Opcoes
        # Versão nova no GitHub? (só avisa; atualizar é no link do rodapé)
        try { Consultar-Atualizacao } catch { }
        Atualizar-Tela
        # Depois do Atualizar-Tela, que é quem lê o estado do bot: painel reaberto com o bot já
        # ligado volta a segurar o WSL (o painel.sh não abre um segundo guardião se ainda há um).
        if ($script:estado['bot'] -in @('active', 'activating', 'deactivating')) { Manter-Vivo }
    } catch {
        Mostrar-Falha $_.Exception.Message
    }
    $form.Cursor = 'Default'
    $timer.Start()
})

[void]$form.ShowDialog()
$timer.Stop()
Encerrar-ConsultaEstado
$script:bandeja.Visible = $false
$script:bandeja.Dispose()
try { $trava.ReleaseMutex() } catch { }
