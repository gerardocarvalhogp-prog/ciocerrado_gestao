#!/usr/bin/env python3
# =====================================================================
# SISTEMA DE GESTAO CIO CERRADO
# rpa_sympla_jantares.py — cria o evento do jantar no Sympla e manda os
# convites, automatizando o painel (Playwright) em vez de chamar API.
#
# POR QUE UM ROBO DE NAVEGADOR EM VEZ DE API
#
# A API publica do Sympla (a mesma que integracao.py ja usa em
# --sympla/--jantares) so' LE dados — eventos, participantes, checkin.
# Nao existe endpoint pra criar evento, subir logo/banner ou lancar
# convite/cortesia. Confirmado antes de escrever isto: a biblioteca
# cliente de referencia da API so' expoe metodos de leitura, e a
# propria Sympla descreve a API publica como "obter informacoes dos
# eventos criados por voce" — puxar dado de la pra fora, nao o
# inverso. Criar e configurar evento continua sendo uma acao so' do
# painel, feita na mao — entao quem faz esse papel aqui e' um robo que
# clica no painel como um humano clicaria.
#
# CALIBRADO A PARTIR DE UMA GRAVACAO REAL (playwright codegen)
#
# Os seletores abaixo vieram de uma gravacao de verdade, criando um
# evento e mandando convite no painel de producao do Sympla — nao sao
# mais placeholder. Ainda assim, teste com --debug antes de confiar em
# --producao: o Sympla pode mudar a tela a qualquer momento, sem
# aviso, e um seletor que sumiu quebra o robo sem dar meio-termo.
#
# LOGIN EM DUAS ETAPAS, SEPARADO DO RESTO
#
# O login do Sympla pede senha + codigo por e-mail + codigo por
# WhatsApp (2FA em duas camadas) — nao da pra automatizar sozinho, o
# robo nao le seu e-mail nem seu WhatsApp. Por isso o login e' um passo
# A PARTE (--login), interativo, rodado por voce UMA VEZ (ou toda vez
# que a sessao expirar): abre o navegador visivel, pede os codigos no
# terminal, e SALVA a sessao autenticada num arquivo
# (sympla_sessao.json). --criar e --convites reaproveitam esse arquivo
# depois — sem repetir OTP a cada execucao, do jeito que a Sympla
# reconhece o dispositivo quando "Mantenha-me conectado" fica marcado.
#
# SEGURANCA POR PADRAO
#
#   - Sem --producao, o robo entra, preenche o formulario, TIRA UM
#     PRINT de cada etapa e PARA antes de publicar/enviar de verdade —
#     mesmo modo seguro do integracao.py (--producao explicito pra
#     valer).
#   - O robo publica o evento (clica "Publicar Evento" + "Entendi") mas
#     PARA AI — a gravacao mostrou que todo evento novo entra "Em
#     analise" no Sympla antes de ficar visivel de verdade, e so' sai
#     dali com um segundo clique manual em "Meus eventos". Isso vira o
#     checkpoint humano antes do evento ficar publico: o organizador
#     confere e publica de verdade quando quiser, o robo nao decide
#     isso sozinho.
#   - As credenciais de login (SYMPLA_EMAIL/SYMPLA_SENHA) sao mais
#     sensiveis que o SYMPLA_TOKEN (a de login abre o painel inteiro,
#     nao so' leitura) — nunca commitar, so' no .env local ou no
#     Agendador de Tarefas, igual as outras chaves. sympla_sessao.json
#     tambem e' sensivel (uma sessao logada de verdade) — nao commitar.
#
# USO
#
#   pip install playwright
#   playwright install chromium
#
#   python rpa_sympla_jantares.py --login              # uma vez, interativo (pede os OTP)
#   python rpa_sympla_jantares.py --criar               # modo seguro, so mostra
#   python rpa_sympla_jantares.py --criar --producao    # cria/publica de verdade
#   python rpa_sympla_jantares.py --convites --producao
#   python rpa_sympla_jantares.py --debug --criar       # navegador visivel, p/ recalibrar
#
# VARIAVEIS DE AMBIENTE (alem de SUPABASE_URL/SUPABASE_SERVICE_KEY, ja
# usadas por integracao.py — reaproveitadas daqui, mesmo .env e mesmo
# cliente Supa):
#
#   SYMPLA_EMAIL   login do painel de produtor do Sympla (nao o SYMPLA_TOKEN da API)
#   SYMPLA_SENHA
#
# A migration 20260909210000 corrigiu is_admin()/is_staff() pra
# reconhecer a service_role tambem (nao so' e-mail cadastrado em
# admins) — por isso este script usa so' a service_role pra tudo,
# igual o integracao.py, sem precisar de uma segunda credencial de
# staff.
# =====================================================================

import os
import sys
import argparse
import logging
import tempfile
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from integracao import Supa, SUPABASE_URL, SUPABASE_SERVICE

try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
except ImportError:
    pass

import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rpa_sympla")

SYMPLA_EMAIL = os.environ.get("SYMPLA_EMAIL", "")
SYMPLA_SENHA = os.environ.get("SYMPLA_SENHA", "")

STORAGE_BUCKET = "jantar-uploads"
SESSAO_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sympla_sessao.json")


# ---------------------------------------------------------------------
# storage: baixa a logo do bucket privado pra um arquivo temporario,
# pra anexar no input de upload do Sympla
# ---------------------------------------------------------------------
def baixar_logo(storage_path):
    url = f"{SUPABASE_URL.rstrip('/')}/storage/v1/object/{STORAGE_BUCKET}/{storage_path}"
    r = requests.get(url, headers={
        "apikey": SUPABASE_SERVICE,
        "Authorization": f"Bearer {SUPABASE_SERVICE}",
    }, timeout=30)
    r.raise_for_status()
    sufixo = os.path.splitext(storage_path)[1] or ".png"
    f = tempfile.NamedTemporaryFile(suffix=sufixo, delete=False)
    f.write(r.content)
    f.close()
    return f.name


# ---------------------------------------------------------------------
# login interativo — roda uma vez (ou quando a sessao expirar), pede os
# codigos de OTP no terminal, salva a sessao autenticada em disco.
#
# A home do Sympla (popup de marketing, campanha, cookie banner) muda
# de visita pra visita — automatizar o caminho ate o formulario de
# e-mail/senha se mostrou a parte mais fragil do fluxo inteiro (dois
# erros diferentes, em pontos diferentes, nas duas primeiras
# tentativas). Em vez de tentar adivinhar cada variante de popup, essa
# parte agora e' MANUAL: o navegador fica visivel, voce mesmo clica
# ate a tela de e-mail e senha (ou ate loga direto se o Sympla lembrar
# do dispositivo) e aperta Enter no terminal — o script so' assume a
# partir dali, onde a tela e' mais estavel (formulario de login de
# verdade, nao pagina de campanha).
#
# A gravacao mostrou um passo de CNPJ/telefone que so' apareceu no
# PRIMEIRO login desta conta (onboarding) — por isso os dois blocos
# "se aparecer" abaixo, com timeout curto, em vez de esperar por algo
# que so' existe na primeira vez.
#
# Qualquer erro daqui pra frente tira um print automatico — nao
# precisa mais pedir prints na mao a cada tentativa.
# ---------------------------------------------------------------------
def login_interativo():
    from playwright.sync_api import sync_playwright

    if not SYMPLA_EMAIL or not SYMPLA_SENHA:
        raise SystemExit("Faltam SYMPLA_EMAIL / SYMPLA_SENHA no ambiente.")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        context = browser.new_context()
        page = context.new_page()

        try:
            page.goto("https://produtores.sympla.com.br/")

            input(
                "\nUma janela do Chrome abriu. Navegue nela até a tela de "
                "e-mail e senha (ex.: 'Crie seu evento agora' > 'Continuar "
                "com e-mail e senha'). Se o Sympla já te logar direto "
                "(lembrou do dispositivo), pule pra 'ÁREA DO PRODUTOR' e "
                "não precisa fazer mais nada aqui — feche essa janela e "
                "cancele este script (Ctrl+C), o login já está pronto.\n"
                "Quando o formulário de e-mail e senha estiver na tela, "
                "pressione Enter aqui: ")

            page.get_by_role("textbox", name="E-mail*").fill(SYMPLA_EMAIL)
            page.get_by_role("textbox", name="Senha*").fill(SYMPLA_SENHA)
            page.get_by_test_id("signin-keep-me-connected-checkbox").check()
            page.get_by_role("button", name="Entrar").click()

            log.info("Verifique seu e-mail: a Sympla mandou um código de confirmação.")
            codigo = input("Código do e-mail (6 dígitos): ").strip()
            for i, digito in enumerate(codigo[:6]):
                page.locator(f"#otp-{i}").fill(digito)
            page.get_by_role("button", name="Continuar").click()

            # onboarding — so' na primeira vez desta conta; timeout curto,
            # pula se nao aparecer. CNPJ da CIO Cerrado Consultoria e
            # Eventos (dado publico de registro, nao e' segredo).
            try:
                page.get_by_test_id("select-trigger-button").click(timeout=5000)
                page.get_by_role("option", name="CNPJ").click()
                page.get_by_role("textbox", name="Qual é o número do documento?").fill("36.631.120/0001-34")
                page.get_by_role("button", name="Continuar").click()
            except Exception:
                pass

            try:
                page.get_by_test_id("whatsapp-button").click(timeout=5000)
                log.info("Verifique seu WhatsApp: a Sympla mandou um segundo código.")
                codigo2 = input("Código do WhatsApp (6 dígitos): ").strip()
                for i, digito in enumerate(codigo2[:6]):
                    page.locator(f"#otp-{i}").fill(digito)
                page.get_by_role("button", name="Continuar").click()
            except Exception:
                pass

            page.get_by_role("link", name="ÁREA DO PRODUTOR").click()
            page.wait_for_load_state("networkidle")

            context.storage_state(path=SESSAO_PATH)
            log.info("Sessão salva em %s — --criar e --convites reaproveitam ela.", SESSAO_PATH)
        except Exception:
            print_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rpa_sympla_login_erro.png")
            try:
                page.screenshot(path=print_path)
                log.error("Deu erro — print da tela no momento da falha salvo em %s", print_path)
            except Exception:
                pass
            raise
        finally:
            browser.close()


def fechar_popup_se_houver(page):
    # o popup de novidade ("Seu evento, ainda mais organizado") nao
    # aparece so' uma vez no inicio — voltou a aparecer bloqueando o
    # upload da logo, bem mais adiante no formulario. Chamar isso
    # antes de qualquer clique que possa esbarrar num popup e' mais
    # seguro do que fechar so' uma vez la no comeco.
    try:
        page.locator(".icon-icon-close").click(timeout=2000)
    except Exception:
        pass


def salvar_print_erro(page, jantar_id):
    # mesma ideia do print automatico do --login: qualquer falha em
    # --criar/--convites salva a tela no momento exato do erro, pra
    # nao precisar pedir print na mao a cada tentativa
    caminho = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            f"rpa_sympla_erro_{jantar_id}.png")
    try:
        page.screenshot(path=caminho)
        log.error("    print da tela no momento da falha salvo em %s", caminho)
    except Exception:
        pass


def abrir_pagina_logada(p, debug):
    if not os.path.exists(SESSAO_PATH):
        raise SystemExit(
            f"Nenhuma sessão salva ({SESSAO_PATH}). Rode primeiro: "
            f"python rpa_sympla_jantares.py --login")
    browser = p.chromium.launch(headless=not debug)
    context = browser.new_context(storage_state=SESSAO_PATH)
    return browser, context.new_page()


# ---------------------------------------------------------------------
# cria o evento pro jantar.
#
# A gravacao original (playwright codegen) mostrou um "modal rapido"
# (data + CEP + preco) antes do formulario completo — mas testado
# contra a conta de producao de verdade, "Criar evento presencial"
# vai direto pra UMA pagina so, com todas as secoes numeradas (Nome,
# Imagem, Classificacao, Data e horario, Local, Ingressos...). O
# "modal rapido" pode ter sido removido pela Sympla, ou so' aparece
# em algum outro caminho — o que importa e' que essa pagina unica e'
# o que a conta real mostra hoje, entao e' isso que o robo segue.
# ---------------------------------------------------------------------
def criar_evento(page, jantar, producao, debug):
    titulo = f"Jantar CIO Cerrado — {jantar['patrocinador_nome']}"
    log.info("Criando evento: %s", titulo)

    data_str = jantar["data"]  # AAAA-MM-DD, vindo do banco
    ano, mes, dia = data_str.split("-")
    data_br = f"{dia}/{mes}/{ano}"
    hora = (jantar.get("horario") or "20:00:00")[:5]  # "HH:MM"

    cep = jantar.get("cep") or ""
    if not cep:
        raise RuntimeError(
            f"jantar '{jantar['patrocinador_nome']}' sem CEP cadastrado — "
            f"preencha em jantares.html antes de rodar o robô.")

    page.goto("https://organizador.sympla.com.br/meus-eventos")
    page.get_by_role("button", name="Criar evento presencial").click()

    # popup de novidade ("Seu evento, ainda mais organizado") que a
    # Sympla mostra por cima do formulário — acontece mais de uma vez
    # na mesma sessão (voltou a aparecer mais adiante, bloqueando o
    # upload da logo), não só na abertura da tela. Esc sozinho não
    # fechou (testado); o X real é <span class="icon icon-icon-close">,
    # achado inspecionando a tela de verdade. fechar_popup_se_houver()
    # e' chamado de novo antes de cada clique que ja esbarrou nele.
    page.wait_for_timeout(800)
    fechar_popup_se_houver(page)

    page.get_by_role("textbox", name="Nome do evento").fill(titulo)

    logo_tmp = None
    if jantar.get("logo_storage_path"):
        logo_tmp = baixar_logo(jantar["logo_storage_path"])
        fechar_popup_se_houver(page)
        # .box-icon-img e' o elemento clicavel de verdade (achado
        # testando contra a tela real) — expect_file_chooser() escuta o
        # dialogo de arquivo que esse clique abre, sem precisar
        # adivinhar QUAL <input type=file> da pagina e' o certo (a
        # pagina pode ter varios escondidos; contar indice quebra fácil)
        with page.expect_file_chooser() as fc_info:
            page.locator(".box-icon-img").first.click()
        fc_info.value.set_files(logo_tmp)

    # jantares nao guarda horario de termino — 3h de duracao e' a
    # mesma janela usada na gravacao que calibrou este script (19h as
    # 22h). Se passar da meia-noite (jantar comecando depois das 21h),
    # cai no fim do dia em vez de virar o dia — mais seguro que
    # arriscar mandar uma data errada pro Sympla.
    try:
        hi = datetime.strptime(hora, "%H:%M")
        hora_fim = min(hi + timedelta(hours=3), hi.replace(hour=23, minute=59)).strftime("%H:%M")
    except ValueError:
        hora, hora_fim = "20:00", "23:00"

    def escolher_horario(texto):
        # o seletor de hora e' o plugin xdsoft_datetimepicker — cada
        # opcao e' um <div class="xdsoft_time" data-hour="19"
        # data-minute="30">, dentro de uma lista ROLAVEL. Bater pelos
        # atributos data-hour/data-minute e' preciso (nao depende do
        # texto renderizado nem de posicao); scroll_into_view_if_needed
        # e' o que faltava antes — o Playwright recusa clicar em algo
        # que existe no HTML mas esta fora da area visivel da rolagem
        # ("element is not visible"), que foi exatamente o erro visto
        # na validacao real.
        h, m = texto.split(":")
        item = page.locator(f'.xdsoft_time[data-hour="{int(h)}"][data-minute="{int(m)}"]')
        item.scroll_into_view_if_needed(timeout=4000)
        item.click(timeout=4000)

    page.locator("#date-from-create-event-time").click()
    page.get_by_role("cell", name=str(int(dia))).click()
    page.locator("#time-from-create-event-time").click()
    escolher_horario(hora)
    page.locator("#date-until-create-event-time").click()
    page.get_by_role("cell", name=str(int(dia))).click()
    page.locator("#time-until-create-event-time").click()
    escolher_horario(hora_fim)

    if jantar.get("mensagem"):
        page.locator(".note-editable").first.fill(jantar["mensagem"])

    # "4. Onde o seu evento vai acontecer" — o dropdown "Local" vem com
    # um endereco salvo de evento anterior escolhido por padrao (a
    # conta ja tem historico); nao da pra digitar CEP direto nele —
    # so' escolhendo "Em um novo endereço" e' que aparece o campo de
    # texto livre. O CEP nunca e' preenchido em campo proprio: vai
    # junto do texto do endereco, que e' provavelmente um autocomplete
    # do Google (por isso o clique na primeira sugestao depois).
    page.get_by_role("combobox", name="Local").select_option(label="Em um novo endereço")

    cep_fmt = f"{cep[:5]}-{cep[5:]}" if len(cep) == 8 else cep
    endereco_texto = f"{jantar['local']}, {cep_fmt}" if jantar.get("local") else cep_fmt
    campo_endereco = page.get_by_role("textbox", name="Informe o endereço ou o nome do local do evento")
    campo_endereco.fill(endereco_texto)
    # autocomplete de endereco (provavelmente Google Places) — escolhe
    # a primeira sugestao se aparecer; segue com o texto livre se nao
    try:
        page.get_by_role("option").first.click(timeout=3000)
    except Exception:
        pass

    fechar_popup_se_houver(page)
    page.get_by_text("Ingresso gratuito").click()
    page.get_by_role("textbox", name="Ex. 100").fill(str(jantar.get("capacidade") or 8))
    page.get_by_role("textbox", name="Ingresso único, Meia-Entrada").fill("Convidado")
    page.get_by_role("button", name="Criar Ingresso").click()

    if debug:
        print_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   f"rpa_sympla_{jantar['id']}_preenchido.png")
        page.screenshot(path=print_path)
        log.info("Print salvo em %s — confira antes de prosseguir.", print_path)

    if logo_tmp:
        os.unlink(logo_tmp)

    if not producao:
        log.warning("MODO SEGURO: formulário preenchido, nada publicado. Use --producao para valer.")
        return None

    fechar_popup_se_houver(page)
    page.get_by_role("checkbox", name="Ao publicar este evento,").check()
    page.get_by_role("button", name="Publicar Evento").click()
    page.get_by_role("button", name="Entendi").click()

    # O evento entra "Em análise" no Sympla — publicar de verdade (o
    # segundo clique, em "Meus eventos") fica por conta do organizador,
    # de propósito: é o checkpoint humano antes do evento ir ao ar.
    page.wait_for_load_state("networkidle")
    abrir_evento_na_lista(page, titulo)
    return page.url


# ---------------------------------------------------------------------
# acha o evento pelo TITULO na lista "Meus eventos" e abre a página de
# gerenciamento dele — em vez de um índice de posição (que dependia de
# quantos outros eventos/links a lista tivesse), usa o título, que é
# determinístico (mesmo texto que criar_evento gerou). name= faz
# combinação parcial por padrão, então bate mesmo com o prefixo de
# status ("Em análise ...", "Publicado ...") que aparece junto na
# gravação.
# ---------------------------------------------------------------------
def abrir_evento_na_lista(page, titulo):
    page.goto("https://organizador.sympla.com.br/meus-eventos")
    page.get_by_role("row", name=titulo).get_by_role("link").click()
    page.wait_for_load_state("networkidle")


# ---------------------------------------------------------------------
# importa a lista de confirmados como convite por e-mail do evento —
# a tela usa UM textarea com todos os e-mails colados, não um convite
# por vez (mais simples do que eu tinha imaginado antes de ver a
# gravação real).
# ---------------------------------------------------------------------
def mandar_convites(page, jantar, confirmados, producao, debug):
    if not confirmados:
        log.info("  %s: nenhum confirmado ainda, pulando.", jantar["patrocinador_nome"])
        return False

    log.info("  %s: %d confirmado(s) para convidar.", jantar["patrocinador_nome"], len(confirmados))

    titulo = f"Jantar CIO Cerrado — {jantar['patrocinador_nome']}"
    abrir_evento_na_lista(page, titulo)
    fechar_popup_se_houver(page)
    page.get_by_role("link", name="Convite por E-mail").click()

    if jantar.get("mensagem"):
        page.locator(".note-editable").fill(jantar["mensagem"])

    page.get_by_text("Lista específica").click()
    emails = "\n".join(c["email"] for c in confirmados if c.get("email"))
    page.get_by_role("textbox", name="Cole ou digite os e-mails dos").fill(emails)
    page.get_by_role("button", name="Adicionar").click()

    if debug:
        print_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   f"rpa_sympla_{jantar['id']}_convite_preview.png")
        page.screenshot(path=print_path)
        log.info("Print salvo em %s", print_path)

    if not producao:
        log.warning("MODO SEGURO: convites não enviados. Use --producao para valer.")
        return False

    fechar_popup_se_houver(page)
    page.locator("#btn-send").click()
    page.wait_for_load_state("networkidle")
    return True


def main():
    ap = argparse.ArgumentParser(description="RPA: cria evento de jantar no Sympla e manda convites")
    ap.add_argument("--login", action="store_true", help="login interativo (pede os OTP), salva a sessão")
    ap.add_argument("--criar", action="store_true", help="cria evento para jantares pendentes")
    ap.add_argument("--convites", action="store_true", help="importa convidados confirmados para eventos já criados")
    ap.add_argument("--producao", action="store_true", help="publica/envia de verdade (padrão é modo seguro)")
    ap.add_argument("--debug", action="store_true", help="navegador visível + prints em /tmp, para recalibrar")
    args = ap.parse_args()

    if args.login:
        login_interativo()
        return 0

    if not (args.criar or args.convites):
        ap.print_help()
        return 1

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise SystemExit("Faltam dependências: pip install playwright && playwright install chromium")

    if not args.producao:
        log.warning("MODO SEGURO: nada será publicado/enviado no Sympla. Use --producao para valer.")

    supa = Supa(SUPABASE_URL, SUPABASE_SERVICE)
    fila = supa.rpc("jantar_listar_para_sympla", {}) or []

    if args.criar:
        pendentes = [j for j in fila if j["sympla_status"] == "pendente"]
        log.info("--- Criar evento: %d jantar(es) pendente(s) ---", len(pendentes))
        if pendentes:
            with sync_playwright() as p:
                browser, page = abrir_pagina_logada(p, args.debug)
                for jantar in pendentes:
                    try:
                        url = criar_evento(page, jantar, args.producao, args.debug)
                        if url:
                            supa.rpc("jantar_marcar_sympla",
                                     {"p_id": jantar["id"], "p_sympla_url": url, "p_status": "criado"})
                            log.info("  %s: enviado para análise em %s", jantar["patrocinador_nome"], url)
                    except Exception as e:
                        salvar_print_erro(page, jantar["id"])
                        log.error("  %s: falhou — %s", jantar["patrocinador_nome"], e)
                browser.close()

    if args.convites:
        prontos = [j for j in fila if j["sympla_status"] == "criado"]
        log.info("--- Convites: %d evento(s) já criado(s) ---", len(prontos))
        if prontos:
            with sync_playwright() as p:
                browser, page = abrir_pagina_logada(p, args.debug)
                for jantar in prontos:
                    try:
                        convidados = supa.rpc("jantar_convidados_listar", {"p_jantar_id": jantar["id"]}) or []
                        confirmados = [c for c in convidados if c.get("status") in ("confirmado", "compareceu")]
                        enviado = mandar_convites(page, jantar, confirmados, args.producao, args.debug)
                        if enviado:
                            supa.rpc("jantar_marcar_sympla",
                                     {"p_id": jantar["id"], "p_sympla_url": None, "p_status": "convites_enviados"})
                    except Exception as e:
                        salvar_print_erro(page, jantar["id"])
                        log.error("  %s: falhou — %s", jantar["patrocinador_nome"], e)
                browser.close()

    log.info("Fim.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
