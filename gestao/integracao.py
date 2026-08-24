#!/usr/bin/env python3
# =====================================================================
# SISTEMA DE GESTAO CIO CERRADO
# integracao.py  ·  Sympla · Autentique · Resend
#
# Roda fora do banco, no Agendador de Tarefas (mesmo lugar do
# rotina_cerrado.py). Fala com o Supabase pela service_role, entao
# ignora RLS de proposito: e um processo de servidor, nao um usuario.
#
# Uso:
#   python integracao.py --tudo
#   python integracao.py --sympla          sincroniza inscricoes
#   python integracao.py --contratos       envia contratos pendentes
#   python integracao.py --status          le status no Autentique
#   python integracao.py --lembretes       cobra quem nao assinou
#   python integracao.py --emails          processa a fila de envio
#
# Por padrao roda em modo seguro (nao envia nada de verdade).
# Use --producao para valer.
# =====================================================================

import os
import sys
import argparse
import logging
from datetime import datetime, timezone, timedelta

import requests

# ---------------------------------------------------------------------
# CONFIGURACAO  (variaveis de ambiente, nunca no codigo)
# ---------------------------------------------------------------------
SUPABASE_URL      = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE  = os.environ.get("SUPABASE_SERVICE_KEY", "")
SYMPLA_TOKEN      = os.environ.get("SYMPLA_TOKEN", "")
AUTENTIQUE_TOKEN  = os.environ.get("AUTENTIQUE_TOKEN", "")
RESEND_KEY        = os.environ.get("RESEND_API_KEY", "")

EVENTO_SLUG       = os.environ.get("CERRADO_EVENTO", "cerrado2027")
REMETENTE         = os.environ.get("CERRADO_REMETENTE", "contato@ciocerrado.com.br")

# Modelo do contrato no Autentique (id do documento base)
AUTENTIQUE_TEMPLATE = os.environ.get("AUTENTIQUE_TEMPLATE_ID", "")

# Lembrete de contrato: dias sem assinar antes da primeira cobranca,
# e intervalo minimo entre uma cobranca e a proxima.
LEMBRETE_APOS_DIAS   = 3
LEMBRETE_INTERVALO   = 4
LEMBRETE_MAXIMO      = 3

SCHEMA = "gestao"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s %(message)s",
    datefmt="%d/%m %H:%M:%S")
log = logging.getLogger("cerrado")


# =====================================================================
# CAMADA SUPABASE
# =====================================================================
class Supa:
    """Acesso ao PostgREST. Todas as chamadas usam o schema gestao."""

    def __init__(self, url, key):
        if not url or not key:
            raise SystemExit(
                "Faltam SUPABASE_URL e SUPABASE_SERVICE_KEY no ambiente.")
        self.base = url.rstrip("/") + "/rest/v1"
        self.h = {
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept-Profile": SCHEMA,     # leitura no schema gestao
            "Content-Profile": SCHEMA,    # escrita no schema gestao
        }

    def get(self, tabela, **params):
        r = requests.get(f"{self.base}/{tabela}", headers=self.h,
                         params=params, timeout=30)
        r.raise_for_status()
        return r.json()

    def patch(self, tabela, filtro, dados):
        r = requests.patch(f"{self.base}/{tabela}", headers=self.h,
                           params=filtro, json=dados, timeout=30)
        r.raise_for_status()
        return r.json() if r.text else []

    def insert(self, tabela, dados, upsert_on=None):
        h = dict(self.h)
        if upsert_on:
            # resolve conflito sem quebrar: e o caso do reprocessamento
            h["Prefer"] = f"resolution=merge-duplicates,return=representation"
        else:
            h["Prefer"] = "return=representation"
        params = {"on_conflict": upsert_on} if upsert_on else {}
        r = requests.post(f"{self.base}/{tabela}", headers=h,
                          params=params, json=dados, timeout=30)
        r.raise_for_status()
        return r.json() if r.text else []

    def evento(self, slug):
        e = self.get("eventos", slug=f"eq.{slug}", select="*", limit=1)
        if not e:
            raise SystemExit(f'Evento "{slug}" nao existe no banco.')
        return e[0]


# =====================================================================
# 1. SYMPLA  →  gestores + participantes
# =====================================================================
def sincronizar_sympla(supa, evento, producao):
    if not SYMPLA_TOKEN:
        log.warning("SYMPLA_TOKEN ausente: pulando sincronizacao.")
        return

    sympla_id = evento.get("sympla_event_id")
    if not sympla_id:
        log.warning("Evento sem sympla_event_id: cadastre no painel (aba Estrutura).")
        return

    log.info("Lendo participantes do Sympla (evento %s)...", sympla_id)

    participantes, pagina = [], 1
    while True:
        r = requests.get(
            f"https://api.sympla.com.br/public/v3/events/{sympla_id}/participants",
            headers={"s_token": SYMPLA_TOKEN},
            params={"page": pagina, "page_size": 200}, timeout=30)
        r.raise_for_status()
        corpo = r.json()
        lote = corpo.get("data", [])
        participantes.extend(lote)

        pg = corpo.get("pagination", {})
        if not pg.get("has_next") or not lote:
            break
        pagina += 1

    log.info("%d inscricao(oes) no Sympla.", len(participantes))

    novos = atualizados = ignorados = 0

    for p in participantes:
        # cancelado no Sympla nao entra nem atualiza
        status_sympla = (p.get("order_status") or "").upper()
        if status_sympla not in ("APPROVED", "APROVADO", "COMPLETE"):
            ignorados += 1
            continue

        email = (p.get("email") or "").strip().lower()
        nome  = (p.get("first_name", "") + " " + p.get("last_name", "")).strip()

        # Sem e-mail nao ha como deduplicar nem enviar contrato.
        if not email or not nome:
            ignorados += 1
            continue

        custom = {c.get("name"): c.get("value")
                  for c in (p.get("custom_form") or [])}

        dados_gestor = {
            "nome": nome,
            "email": email,
            "empresa": custom.get("Empresa") or p.get("company"),
            "cargo": custom.get("Cargo"),
            "telefone": p.get("phone"),
            "origem": "importacao",
        }
        dados_gestor = {k: v for k, v in dados_gestor.items() if v}

        if not producao:
            log.info("  [seguro] %s <%s>", nome, email)
            continue

        g = supa.insert("gestores", dados_gestor, upsert_on="email_norm")
        if not g:
            g = supa.get("gestores", email=f"eq.{email}", select="id", limit=1)
        gestor_id = g[0]["id"]

        ja = supa.get("participantes",
                      evento_id=f"eq.{evento['id']}",
                      gestor_id=f"eq.{gestor_id}",
                      select="id,status", limit=1)

        if ja:
            atualizados += 1
        else:
            supa.insert("participantes", {
                "evento_id": evento["id"],
                "gestor_id": gestor_id,
                "sympla_id": str(p.get("id")),
                "tipo_ingresso": p.get("ticket_name"),
                # aprovacao continua sendo decisao humana no painel
                "status": "pendente",
                "origem": "sympla",
            })
            novos += 1

    log.info("Sympla: %d novo(s), %d ja existiam, %d ignorado(s).",
             novos, atualizados, ignorados)


# =====================================================================
# 2. AUTENTIQUE  →  envio e status
# =====================================================================
AUTENTIQUE_API = "https://api.autentique.com.br/v2/graphql"


def autentique(query, variaveis=None):
    r = requests.post(
        AUTENTIQUE_API,
        headers={"Authorization": f"Bearer {AUTENTIQUE_TOKEN}"},
        json={"query": query, "variables": variaveis or {}}, timeout=40)
    r.raise_for_status()
    corpo = r.json()
    if corpo.get("errors"):
        raise RuntimeError(corpo["errors"][0].get("message", "erro Autentique"))
    return corpo.get("data", {})


def enviar_contratos(supa, evento, producao):
    if not AUTENTIQUE_TOKEN:
        log.warning("AUTENTIQUE_TOKEN ausente: pulando envio.")
        return

    # aprovados que ainda nao receberam contrato
    pend = supa.get(
        "contratos",
        select="id,participante_id,status,participantes!inner(evento_id,status,gestores!inner(nome,email))",
        status="eq.nao_enviado")

    alvo = [c for c in pend
            if c["participantes"]["evento_id"] == evento["id"]
            and c["participantes"]["status"] == "aprovado"]

    log.info("%d contrato(s) para enviar.", len(alvo))

    for c in alvo:
        g = c["participantes"]["gestores"]
        if not producao:
            log.info("  [seguro] contrato para %s <%s>", g["nome"], g["email"])
            continue

        try:
            dados = autentique("""
              mutation($documento: DocumentInput!, $signatarios: [SignerInput!]!) {
                createDocumentFromTemplate(
                  template_id: "%s", document: $documento, signers: $signatarios
                ) { id name }
              }""" % AUTENTIQUE_TEMPLATE,
              {
                "documento": {"name": f"Contrato · {g['nome']}"},
                "signatarios": [{"email": g["email"], "action": "SIGN"}],
              })

            doc = dados["createDocumentFromTemplate"]
            supa.patch("contratos", {"id": f"eq.{c['id']}"}, {
                "autentique_id": doc["id"],
                "autentique_url": f"https://app.autentique.com.br/documentos/{doc['id']}",
                "status": "enviado",
                "enviado_em": agora(),
            })
            enfileirar(supa, evento, g["email"], "contrato_enviado",
                       "Seu contrato do CIO Cerrado Experience")
            log.info("  enviado: %s", g["email"])

        except Exception as e:
            # um contrato que falha nao pode parar a fila inteira
            log.error("  falhou para %s: %s", g["email"], e)


def ler_status(supa, evento, producao):
    if not AUTENTIQUE_TOKEN:
        log.warning("AUTENTIQUE_TOKEN ausente: pulando leitura de status.")
        return

    abertos = supa.get("contratos", select="id,autentique_id,participante_id",
                       status="eq.enviado")
    abertos = [c for c in abertos if c.get("autentique_id")]
    log.info("Conferindo %d contrato(s) em aberto...", len(abertos))

    assinados = 0
    for c in abertos:
        try:
            d = autentique("""
              query($id: UUID!) {
                document(id: $id) { id signatures { signed { created_at } } }
              }""", {"id": c["autentique_id"]})

            assinaturas = d["document"]["signatures"]
            if any(s.get("signed") for s in assinaturas):
                if producao:
                    supa.patch("contratos", {"id": f"eq.{c['id']}"},
                               {"status": "assinado", "assinado_em": agora()})
                    avisar_participante(supa, evento, c["participante_id"],
                                        "contrato_assinado",
                                        "Contrato assinado — complete sua hospedagem")
                assinados += 1
        except Exception as e:
            log.error("  erro no documento %s: %s", c["autentique_id"], e)

    log.info("%d assinatura(s) nova(s).", assinados)


# =====================================================================
# 3. LEMBRETES
# =====================================================================
def lembretes(supa, evento, producao):
    """Cobra quem recebeu o contrato e nao assinou."""
    hoje = datetime.now(timezone.utc)
    corte_primeiro = hoje - timedelta(days=LEMBRETE_APOS_DIAS)
    corte_repeticao = hoje - timedelta(days=LEMBRETE_INTERVALO)

    pend = supa.get(
        "contratos",
        select="id,lembretes_enviados,ultimo_lembrete_em,enviado_em,"
               "participantes!inner(evento_id,gestores!inner(nome,email))",
        status="eq.enviado")

    prazo = evento.get("prazo_contrato")
    enviados = 0

    for c in pend:
        if c["participantes"]["evento_id"] != evento["id"]:
            continue
        if (c.get("lembretes_enviados") or 0) >= LEMBRETE_MAXIMO:
            continue
        if not c.get("enviado_em"):
            continue

        enviado = iso(c["enviado_em"])
        if enviado > corte_primeiro:
            continue                       # ainda e cedo para cobrar

        ultimo = iso(c["ultimo_lembrete_em"]) if c.get("ultimo_lembrete_em") else None
        if ultimo and ultimo > corte_repeticao:
            continue                       # cobrado ha pouco

        g = c["participantes"]["gestores"]
        assunto = "Lembrete: seu contrato ainda não foi assinado"
        if prazo:
            assunto += f" (prazo {br(prazo)})"

        if not producao:
            log.info("  [seguro] lembrete para %s", g["email"])
            continue

        enfileirar(supa, evento, g["email"], "contrato_lembrete", assunto)
        supa.patch("contratos", {"id": f"eq.{c['id']}"}, {
            "lembretes_enviados": (c.get("lembretes_enviados") or 0) + 1,
            "ultimo_lembrete_em": agora(),
        })
        enviados += 1

    log.info("%d lembrete(s) enfileirado(s).", enviados)


# =====================================================================
# 4. FILA DE E-MAILS  →  Resend
# =====================================================================
CORPO = {
    "contrato_enviado":
        "Olá, {nome}.\n\n"
        "Seu contrato do CIO Cerrado Experience já está disponível para assinatura. "
        "Assim que assinar, o preenchimento dos dados de hospedagem é liberado.\n\n"
        "{link}\n\nEquipe CIO Cerrado",
    "contrato_lembrete":
        "Olá, {nome}.\n\n"
        "Seu contrato ainda está aguardando assinatura. Sem ela não conseguimos "
        "confirmar sua hospedagem.\n\n{link}\n\nEquipe CIO Cerrado",
    "contrato_assinado":
        "Olá, {nome}.\n\n"
        "Contrato assinado, obrigado. Agora complete seus dados de hospedagem "
        "— quem vai com você e se vai usar o transfer.\n\n{link}\n\nEquipe CIO Cerrado",
    "inscricao_aprovada":
        "Olá, {nome}.\n\n"
        "Sua inscrição no CIO Cerrado Experience foi aprovada. "
        "Em instantes você recebe o contrato para assinatura.\n\nEquipe CIO Cerrado",
    "autocadastro_recebido":
        "Olá, {nome}.\n\n"
        "Recebemos seu cadastro. Nossa equipe avalia e responde por aqui.\n\n"
        "Equipe CIO Cerrado",
    "rooming_ok":
        "Olá, {nome}.\n\n"
        "Seus dados de hospedagem foram confirmados. "
        "Se precisar mudar algo, é só voltar ao link.\n\n{link}\n\nEquipe CIO Cerrado",
}

PADRAO = "Olá, {nome}.\n\n{assunto}\n\nEquipe CIO Cerrado"


def processar_emails(supa, evento, producao, limite=200):
    if not RESEND_KEY:
        log.warning("RESEND_API_KEY ausente: pulando envio de e-mail.")
        return

    fila = supa.get("notificacoes", select="*",
                    status="eq.enfileirada",
                    evento_id=f"eq.{evento['id']}",
                    order="created_at.asc", limit=limite)

    log.info("%d e-mail(s) na fila.", len(fila))
    ok = falhou = 0

    for n in fila:
        nome = (n.get("destinatario") or "").split("@")[0]
        modelo = CORPO.get(n["tipo"], PADRAO)
        texto = modelo.format(nome=nome,
                              assunto=n.get("assunto") or "",
                              link=link_do_tipo(n["tipo"]))

        if not producao:
            log.info("  [seguro] %s -> %s", n["tipo"], n["destinatario"])
            continue

        try:
            r = requests.post(
                "https://api.resend.com/emails",
                headers={"Authorization": f"Bearer {RESEND_KEY}"},
                json={
                    "from": f"CIO Cerrado <{REMETENTE}>",
                    "to": [n["destinatario"]],
                    "subject": n.get("assunto") or "CIO Cerrado Experience",
                    "text": texto,
                }, timeout=30)
            r.raise_for_status()

            supa.patch("notificacoes", {"id": f"eq.{n['id']}"},
                       {"status": "enviada", "enviada_em": agora()})
            ok += 1

        except Exception as e:
            # marca o erro na propria linha: assim da para ver no painel
            # por que aquele e-mail nunca chegou
            supa.patch("notificacoes", {"id": f"eq.{n['id']}"},
                       {"status": "erro", "erro": str(e)[:500]})
            falhou += 1
            log.error("  falhou %s: %s", n["destinatario"], e)

    log.info("E-mails: %d enviado(s), %d com erro.", ok, falhou)


def link_do_tipo(tipo):
    base = os.environ.get("CERRADO_SITE", "https://ciocerrado.netlify.app")
    if tipo.startswith("contrato"):
        return f"{base}/rooming.html?evento={EVENTO_SLUG}"
    return f"{base}/rooming.html?evento={EVENTO_SLUG}"


# =====================================================================
# APOIO
# =====================================================================
def agora():
    return datetime.now(timezone.utc).isoformat()


def iso(v):
    """Aceita os dois formatos que o PostgREST devolve."""
    if not v:
        return None
    v = v.replace("Z", "+00:00")
    d = datetime.fromisoformat(v)
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def br(d):
    return "/".join(reversed(str(d)[:10].split("-")))


def enfileirar(supa, evento, email, tipo, assunto):
    supa.insert("notificacoes", {
        "evento_id": evento["id"], "destinatario": email,
        "tipo": tipo, "assunto": assunto, "status": "enfileirada"})


def avisar_participante(supa, evento, participante_id, tipo, assunto):
    p = supa.get("participantes", select="gestores!inner(email)",
                 id=f"eq.{participante_id}", limit=1)
    if p:
        enfileirar(supa, evento, p[0]["gestores"]["email"], tipo, assunto)


# =====================================================================
# MAIN
# =====================================================================
def main():
    ap = argparse.ArgumentParser(description="Integracoes do CIO Cerrado")
    ap.add_argument("--tudo",      action="store_true")
    ap.add_argument("--sympla",    action="store_true")
    ap.add_argument("--contratos", action="store_true")
    ap.add_argument("--status",    action="store_true")
    ap.add_argument("--lembretes", action="store_true")
    ap.add_argument("--emails",    action="store_true")
    ap.add_argument("--producao",  action="store_true",
                    help="envia de verdade (padrao e modo seguro)")
    ap.add_argument("--evento", default=EVENTO_SLUG)
    args = ap.parse_args()

    if not any([args.tudo, args.sympla, args.contratos,
                args.status, args.lembretes, args.emails]):
        ap.print_help()
        return 1

    if not args.producao:
        log.warning("MODO SEGURO: nada sera enviado. Use --producao para valer.")

    supa = Supa(SUPABASE_URL, SUPABASE_SERVICE)
    evento = supa.evento(args.evento)
    log.info("Evento: %s (%s)", evento["nome"], evento["slug"])

    # A ordem importa: sincroniza, envia, confere, cobra e so entao
    # despacha a fila — assim tudo que foi gerado agora ja sai junto.
    passos = [
        (args.tudo or args.sympla,    "Sympla",    sincronizar_sympla),
        (args.tudo or args.contratos, "Contratos", enviar_contratos),
        (args.tudo or args.status,    "Status",    ler_status),
        (args.tudo or args.lembretes, "Lembretes", lembretes),
        (args.tudo or args.emails,    "E-mails",   processar_emails),
    ]

    for ativo, nome, funcao in passos:
        if not ativo:
            continue
        log.info("--- %s ---", nome)
        try:
            funcao(supa, evento, args.producao)
        except Exception as e:
            # um passo que quebra nao pode impedir os seguintes
            log.error("%s falhou: %s", nome, e)

    log.info("Fim.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
