# Número operacional — grupos de WhatsApp dos jantares

Processo Node de vida longa, fora do Supabase (Edge Function não segura sessão
viva). Faz **só** três coisas: sincroniza contato no Google, cria o grupo do
jantar, gera o link de convite. **Nunca manda mensagem** — quem manda é o
número 1 (Cloud API oficial da Meta), já coberto pela Edge Function
`enviar-whatsapp` existente.

Ver a proposta completa (Fase 1, aprovada) na conversa do Claude Code que
criou este módulo, e os comentários no topo de
`supabase/migrations/20260912090000_grupos_whatsapp_jantares.sql`.

## Instalação

```
cd gestao/whatsapp_operacional
npm install
cp .env.example .env
```

## Modo de teste (padrão — comece por aqui)

Com `WHATSAPP_MODO=teste` (o padrão, mesmo sem essa linha no `.env`), o
daemon roda o pipeline inteiro — poll, sincronização "de contato", criação de
"grupo", enfileiramento de convite — **sem tocar WhatsApp nem Google de
verdade**. Só precisa de `SUPABASE_URL`/`SUPABASE_SERVICE_KEY` preenchidos:

```
npm start
```

Peça pra um admin clicar "Criar grupo" em algum jantar com convidado
confirmado (jantares.html) e acompanhe o terminal: cada etapa loga o que
*seria* feito, com `resource_name`/`jid`/link simulados (prefixo `TESTE-`), e
grava tudo normalmente no banco — dá pra testar a tela inteira de ponta a
ponta sem nenhuma credencial de WhatsApp ou Google.

## Rodando de verdade (produção)

Precisa, antes de tudo, do que está listado na Fase 1 como dependência de
terceiro: verificação de negócio no Meta (canal 1, fora deste diretório — ver
`enviar-whatsapp`), número operacional físico com WhatsApp já instalado, e
projeto Google Cloud com People API habilitada.

### Primeira autorização do Google People API

Não dá pra usar uma service account pura (ela não tem agenda própria — mesmo
motivo do `robo-fichas` no Drive, documentado no `CLAUDE.md`). O caminho é
OAuth de um usuário real do Workspace do CIO Cerrado, uma vez, guardando o
refresh token:

1. No [Google Cloud Console](https://console.cloud.google.com), crie (ou
   reaproveite) um projeto, habilite a **People API**.
2. **APIs & Services → Credentials → Create Credentials → OAuth client ID**,
   tipo **Desktop app**. Copie o Client ID e o Client Secret.
3. Preencha `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` no `.env`.
4. `npm run obter-token` — abre um link, você autoriza com a conta Google que
   vai servir de agenda (a mesma cujos contatos o app vai comparar/criar),
   cola o código de volta no terminal. Sai um `GOOGLE_REFRESH_TOKEN=...`,
   cola no `.env`.

### Primeira conexão do número operacional

1. Preencha `WHATSAPP_PERFIL_NOME` (e `WHATSAPP_PERFIL_FOTO_PATH`, se quiser
   já subir foto na primeira conexão).
2. Mude `WHATSAPP_MODO=producao` no `.env`.
3. Com o **aparelho físico do número operacional** em mãos:
   ```
   npm run conectar
   ```
4. Escaneie o QR que aparece no terminal (Aparelho → Configurações →
   Aparelhos conectados → Conectar um aparelho). Expira em ~20s — se sumir
   antes de escanear, espera o próximo.
5. Conectado, o script configura nome/foto do perfil sozinho, grava um log de
   sessão conectada, e sai. A sessão fica salva em `WHATSAPP_SESSAO_DIR`
   (`./sessao` por padrão).
6. Dali em diante, `npm start` reconecta **sem pedir QR de novo** — só volta a
   pedir se a sessão for deslogada no próprio aparelho.

### Rodando o daemon

```
npm start
```

Fica de pé, faz poll em `jantar_grupos` a cada `WHATSAPP_POLL_INTERVALO_MS`
(15s por padrão) e processa o que estiver pendente. Ctrl+C pra parar — retoma
de onde parou na próxima vez (nada em memória, tudo no banco).

## Migração pra VPS

Só muda `WHATSAPP_SESSAO_DIR` pro caminho do volume persistente na VPS (IP
fixo, Brasil) e copia a pasta de sessão pra lá — nenhum código muda. Rodar
como serviço (`systemd`, `pm2`, o que preferir) em vez de terminal aberto.

## Log

Toda ação (conexão, desconexão, contato sincronizado/criado, grupo criado,
erro) vira uma linha em `whatsapp_operacional_log`, com timestamp — inclusive
as que não têm jantar associado (conexão/desconexão de sessão, `jantar_id`
null).
