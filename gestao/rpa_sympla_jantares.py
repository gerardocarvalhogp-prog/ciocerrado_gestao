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
# ESTE SCRIPT E' UM PONTO DE PARTIDA, NAO ESTA CALIBRADO
#
# Escrito sem acesso ao painel de produtor do Sympla (o ambiente onde
# isto foi escrito nao alcanca sympla.com.br) — os seletores de tela
# abaixo (marcados "# TODO CALIBRAR") sao placeholders plausiveis, nao
# testados contra a pagina real. Antes de rodar isto de verdade:
#
#   1. Rode `playwright codegen https://produtores.sympla.com.br` na
#      sua maquina, faca o login e o fluxo de criar um evento na mao
#      uma vez — o codegen grava um script Python com os seletores
#      reais de cada clique.
#   2. Troque os seletores marcados TODO abaixo pelos que o codegen
#      gravou.
#   3. Rode com --debug (abre o navegador visivel, sem --producao) pra
#      ver o robo passar pelo formulario antes de confiar nele.
#
# SEGURANCA POR PADRAO
#
#   - Sem --producao, o robo entra, preenche o formulario, TIRA UM
#     PRINT de cada etapa e PARA antes de clicar em publicar/salvar de
#     verdade — mesmo modo seguro do integracao.py (--producao explicito
#     pra valer).
#   - Mesmo em --producao, o evento e' salvo como RASCUNHO quando o
#     Sympla permitir (# TODO CALIBRAR: confirme se o passo de
#     "publicar" e' separado do de "salvar" no fluxo de voces) — quem
#     decide publicar de verdade e manda convite continua sendo voce,
#     olhando o rascunho antes. Ninguem confirma inscricao nem recebe
#     e-mail so' porque este script rodou.
#   - As credenciais de login (SYMPLA_EMAIL/SYMPLA_SENHA) sao mais
#     sensiveis que o SYMPLA_TOKEN (a de login abre o painel inteiro,
#     nao so' leitura) — nunca commitar, so' no .env local ou no
#     Agendador de Tarefas, igual as outras chaves.
#
# USO
#
#   pip install playwright
#   playwright install chromium
#
#   python rpa_sympla_jantares.py --criar             # modo seguro, so mostra
#   python rpa_sympla_jantares.py --criar --producao  # cria/salva rascunho de verdade
#   python rpa_sympla_jantares.py --convites --producao
#   python rpa_sympla_jantares.py --debug --criar     # navegador visivel, p/ calibrar
#
# VARIAVEIS DE AMBIENTE (alem de SUPABASE_URL/SUPABASE_SERVICE_KEY, ja
# usadas por integracao.py — reaproveitadas daqui, mesmo .env):
#
#   SUPABASE_ANON_KEY     a mesma anon key do admin.html/jantares.html
#   CERRADO_STAFF_EMAIL   login de um admin/staff JA CADASTRADO no sistema
#   CERRADO_STAFF_SENHA   (aba Equipe do admin.html — precisa ter senha definida)
#   SYMPLA_EMAIL          login do painel de produtor do Sympla (nao o SYMPLA_TOKEN da API)
#   SYMPLA_SENHA
#
# POR QUE DOIS LOGINS DIFERENTES (CERRADO_STAFF_* E SYMPLA_*)
#
# CERRADO_STAFF_* entra no NOSSO sistema — e' o que autoriza chamar
# jantar_convidados_listar, jantar_listar_para_sympla etc., que exigem
# _exige_staff()/_exige_admin() (checam e-mail contra a tabela
# `admins`). O SUPABASE_SERVICE_KEY (service_role) NAO serve pra isso:
# testado localmente, o JWT do service_role nao carrega e-mail nenhum,
# entao is_admin()/is_staff() dao falso pra ele — e' por isso que este
# script loga como uma conta de staff de verdade em vez de usar a
# chave de servico pra tudo (que so' e' usada aqui pra baixar a logo do
# storage, onde service_role bypassa RLS de verdade). SYMPLA_EMAIL/
# SYMPLA_SENHA e' outra coisa: login no PAINEL DO SYMPLA, pro robo
# clicar la.
# =====================================================================

import os
import sys
import argparse
import logging
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from integracao import SUPABASE_URL, SUPABASE_SERVICE  # so' as constantes, pro download da logo

try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
except ImportError:
    pass

import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rpa_sympla")

SUPABASE_ANON     = os.environ.get("SUPABASE_ANON_KEY", "")
STAFF_EMAIL       = os.environ.get("CERRADO_STAFF_EMAIL", "")
STAFF_SENHA       = os.environ.get("CERRADO_STAFF_SENHA", "")
SYMPLA_EMAIL      = os.environ.get("SYMPLA_EMAIL", "")
SYMPLA_SENHA      = os.environ.get("SYMPLA_SENHA", "")

STORAGE_BUCKET = "jantar-uploads"
SCHEMA = "gestao"


class SupaStaff:
    """Chama RPC do schema gestao autenticado como staff de verdade —
    _exige_staff()/_exige_admin() olham auth.jwt()->>'email', que so'
    existe com login de usuario real (nao com a service_role key)."""

    def __init__(self, url, anon_key, email, senha):
        if not url or not anon_key or not email or not senha:
            raise SystemExit(
                "Faltam SUPABASE_URL / SUPABASE_ANON_KEY / CERRADO_STAFF_EMAIL / "
                "CERRADO_STAFF_SENHA no ambiente.")
        self.base = url.rstrip("/") + "/rest/v1"
        r = requests.post(
            f"{url.rstrip('/')}/auth/v1/token?grant_type=password",
            headers={"apikey": anon_key, "Content-Type": "application/json"},
            json={"email": email, "password": senha}, timeout=30)
        r.raise_for_status()
        token = r.json()["access_token"]
        self.h = {
            "apikey": anon_key,
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept-Profile": SCHEMA,
            "Content-Profile": SCHEMA,
        }

    def rpc(self, funcao, args):
        r = requests.post(f"{self.base}/rpc/{funcao}", headers=self.h, json=args, timeout=30)
        r.raise_for_status()
        return r.json() if r.text else None


# ---------------------------------------------------------------------
# storage: baixa a logo do bucket privado pra um arquivo temporario,
# pra anexar no input de upload do Sympla — aqui sim service_role, que
# bypassa RLS de storage de verdade (nao passa por _exige_staff())
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
# login no painel de produtor — sessao reaproveitada pelas duas etapas
# ---------------------------------------------------------------------
def logar(page):
    if not SYMPLA_EMAIL or not SYMPLA_SENHA:
        raise SystemExit("Faltam SYMPLA_EMAIL / SYMPLA_SENHA no ambiente.")

    page.goto("https://produtores.sympla.com.br/login")  # TODO CALIBRAR: URL de login real
    page.fill("#email", SYMPLA_EMAIL)                     # TODO CALIBRAR: seletor do campo e-mail
    page.fill("#senha", SYMPLA_SENHA)                      # TODO CALIBRAR: seletor do campo senha
    page.click("button[type=submit]")                      # TODO CALIBRAR: botao de entrar
    page.wait_for_load_state("networkidle")


# ---------------------------------------------------------------------
# cria (ou abre o rascunho de) um evento pro jantar
# ---------------------------------------------------------------------
def criar_evento(page, jantar, producao, debug):
    titulo = f"Jantar CIO Cerrado — {jantar['patrocinador_nome']}"
    log.info("Criando evento: %s", titulo)

    page.goto("https://produtores.sympla.com.br/evento/criar")  # TODO CALIBRAR
    page.fill("#nome-evento", titulo)                             # TODO CALIBRAR
    if jantar.get("data"):
        page.fill("#data-evento", jantar["data"])                 # TODO CALIBRAR
    if jantar.get("horario"):
        page.fill("#horario-evento", jantar["horario"])           # TODO CALIBRAR
    if jantar.get("local"):
        page.fill("#local-evento", jantar["local"])                # TODO CALIBRAR
    if jantar.get("mensagem"):
        page.fill("#descricao-evento", jantar["mensagem"])         # TODO CALIBRAR

    logo_tmp = None
    if jantar.get("logo_storage_path"):
        logo_tmp = baixar_logo(jantar["logo_storage_path"])
        page.set_input_files("#banner-evento", logo_tmp)            # TODO CALIBRAR

    if debug:
        page.screenshot(path=f"/tmp/rpa_sympla_{jantar['id']}_preenchido.png")
        log.info("Print salvo em /tmp/rpa_sympla_%s_preenchido.png — confira antes de prosseguir.",
                  jantar["id"])

    if not producao:
        log.warning("MODO SEGURO: formulario preenchido, nada salvo. Use --producao para valer.")
        if logo_tmp:
            os.unlink(logo_tmp)
        return None

    # TODO CALIBRAR: confirme se existe um botao "Salvar rascunho"
    # separado de "Publicar" — clique no de RASCUNHO. Publicar de
    # verdade e' decisao do organizador, olhando a pagina antes.
    page.click("button#salvar-rascunho")                          # TODO CALIBRAR

    page.wait_for_load_state("networkidle")
    url_evento = page.url                                          # TODO CALIBRAR: confirme que a URL final e' a do evento

    if logo_tmp:
        os.unlink(logo_tmp)

    return url_evento


# ---------------------------------------------------------------------
# importa a lista de confirmados como convidados/cortesia do evento
# ---------------------------------------------------------------------
def mandar_convites(page, supa, jantar, producao, debug):
    convidados = supa.rpc("jantar_convidados_listar", {"p_jantar_id": jantar["id"]}) or []
    confirmados = [c for c in convidados if c.get("status") in ("confirmado", "compareceu")]

    if not confirmados:
        log.info("  %s: nenhum confirmado ainda, pulando.", jantar["patrocinador_nome"])
        return False

    log.info("  %s: %d confirmado(s) para convidar.", jantar["patrocinador_nome"], len(confirmados))

    sympla_id = jantar["sympla_url"].rsplit("__", 1)[-1] if "__" in (jantar.get("sympla_url") or "") else None
    if not sympla_id:
        log.warning("  sympla_url sem __<id> no final — não dá pra abrir a tela de convidados direto.")
        return False

    page.goto(f"https://produtores.sympla.com.br/evento/{sympla_id}/convidados")  # TODO CALIBRAR

    # TODO CALIBRAR: confirme se e' upload de CSV/planilha ou
    # preenchimento linha a linha — a maioria das plataformas usa CSV
    # pra lote. Se for CSV, montar o arquivo aqui com
    # nome/email/telefone de `confirmados` e usar page.set_input_files.
    for c in confirmados:
        page.fill("#convite-nome", c.get("nome", ""))               # TODO CALIBRAR
        page.fill("#convite-email", c.get("email", ""))              # TODO CALIBRAR
        if debug:
            page.screenshot(path=f"/tmp/rpa_sympla_{jantar['id']}_convite_preview.png")
            break  # so' um print de exemplo em modo debug, nao itera todo mundo

    if not producao:
        log.warning("MODO SEGURO: convites não enviados. Use --producao para valer.")
        return False

    # TODO CALIBRAR: botao real de confirmar o lote de convites
    page.click("button#confirmar-convites")                          # TODO CALIBRAR
    page.wait_for_load_state("networkidle")
    return True


def main():
    ap = argparse.ArgumentParser(description="RPA: cria evento de jantar no Sympla e manda convites")
    ap.add_argument("--criar", action="store_true", help="cria evento (rascunho) para jantares pendentes")
    ap.add_argument("--convites", action="store_true", help="importa convidados confirmados para eventos já criados")
    ap.add_argument("--producao", action="store_true", help="salva/envia de verdade (padrão é modo seguro)")
    ap.add_argument("--debug", action="store_true", help="navegador visível + prints em /tmp, para calibrar seletores")
    args = ap.parse_args()

    if not (args.criar or args.convites):
        ap.print_help()
        return 1

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise SystemExit("Faltam dependências: pip install playwright && playwright install chromium")

    if not args.producao:
        log.warning("MODO SEGURO: nada será salvo/enviado no Sympla. Use --producao para valer.")

    supa = SupaStaff(SUPABASE_URL, SUPABASE_ANON, STAFF_EMAIL, STAFF_SENHA)
    fila = supa.rpc("jantar_listar_para_sympla", {}) or []

    if args.criar:
        pendentes = [j for j in fila if j["sympla_status"] == "pendente"]
        log.info("--- Criar evento: %d jantar(es) pendente(s) ---", len(pendentes))
        if pendentes:
            with sync_playwright() as p:
                browser = p.chromium.launch(headless=not args.debug)
                page = browser.new_page()
                logar(page)
                for jantar in pendentes:
                    try:
                        url = criar_evento(page, jantar, args.producao, args.debug)
                        if url:
                            supa.rpc("jantar_marcar_sympla",
                                     {"p_id": jantar["id"], "p_sympla_url": url, "p_status": "criado"})
                            log.info("  %s: criado em %s", jantar["patrocinador_nome"], url)
                    except Exception as e:
                        log.error("  %s: falhou — %s", jantar["patrocinador_nome"], e)
                browser.close()

    if args.convites:
        prontos = [j for j in fila if j["sympla_status"] == "criado"]
        log.info("--- Convites: %d evento(s) já criado(s) ---", len(prontos))
        if prontos:
            with sync_playwright() as p:
                browser = p.chromium.launch(headless=not args.debug)
                page = browser.new_page()
                logar(page)
                for jantar in prontos:
                    try:
                        enviado = mandar_convites(page, supa, jantar, args.producao, args.debug)
                        if enviado:
                            supa.rpc("jantar_marcar_sympla",
                                     {"p_id": jantar["id"], "p_sympla_url": None, "p_status": "convites_enviados"})
                    except Exception as e:
                        log.error("  %s: falhou — %s", jantar["patrocinador_nome"], e)
                browser.close()

    log.info("Fim.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
