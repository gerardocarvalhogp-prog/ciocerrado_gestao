# Consentimento IBM — CIO Cerrado Experience 2026

Sistema para coletar e comprovar o aceite (ou a recusa) dos participantes quanto ao
compartilhamento de dados com a IBM, e gerar o **Leads Report** no layout exigido por ela.

## Arquivos

| Arquivo | O que é |
|---|---|
| `01_schema_consentimento_ibm.sql` | Tabelas, RLS, funções e **seed com os 154 inscritos aprovados** |
| `consentimento.html` | Formulário público (link enviado aos convidados) |
| `admin_consentimento.html` | Relatório restrito + exportações em Excel |
| `textos_para_envio.md` | E-mail, WhatsApp, lembrete, versão em inglês e texto das placas |

## Acesso do participante

Duas informacoes na tela inicial: **e-mail da inscricao + CPF ou data de nascimento**. Serve
qualquer um dos dois — quem nao lembra a data digita o CPF. Confirmada a identidade, a pessoa
ve a ficha dela (nome, empresa, cargo, e-mail, telefone) antes de responder, e pode corrigir o
telefone ali mesmo.

O CPF e a data **nao sao gravados**: o seed sobe apenas o hash SHA-256 com pepper, e a
comparacao acontece dentro do banco. Cinco tentativas erradas bloqueiam aquele e-mail por 15
minutos. Erro de e-mail e erro de chave devolvem a mesma mensagem, para nao confirmar a
estranhos quem esta inscrito.

## Como as duas perguntas viraram registro

- **Item A (Data Privacy)** — informativo, sem ação do usuário. Aparece em destaque na tela e fica gravado no campo `dp_exibido`, junto com a versão do texto exibido (`texto_versao`).
- **Item B (Notice & Choice)** — checkbox **opcional e desmarcado por padrão**, com o texto e os três links exatamente como a IBM pediu.
- Como o Leads Report tem colunas separadas de `Opt in Email` e `Opt in Phone`, o N&C foi dividido em dois checkboxes. Marcar qualquer um dos dois = `aceito`.
- Enviar o formulário **sem marcar nada** grava `recusado` com data e hora. É assim que você tem o "não" registrado em vez de um campo em branco — que é o que a auditoria da IBM não aceita.
- `ibm_consent_log` guarda todas as respostas, inclusive quando alguém muda de ideia. A tabela principal guarda a resposta vigente.

## Publicação (30 minutos)

1. **Supabase** — no mesmo projeto do agendamento de massagem, cole `01_schema_consentimento_ibm.sql` no SQL Editor e execute. Ao final ele mostra a contagem por status (deve dar 154 pendentes).
2. **Chaves** — preencha `SUPABASE_URL` e `SUPABASE_ANON_KEY` no topo do `<script>` dos dois HTMLs. São as mesmas do app de massagem.
3. **Pepper** — o `PEPPER` esta na funcao `ibm_pepper()`, no inicio do SQL. Se voce trocar, os hashes do seed param de bater e o seed precisa ser gerado de novo. Melhor deixar como esta.
4. **Admins** — no SQL, as policies liberam leitura para `kelson.duarte@`, `tacio.henrique@` e `comunicacao@ciocerrado.com.br`. Ajuste a lista se precisar (aparece em dois lugares).
5. **Logos** — suba `logo-cio-cerrado.webp` e `logo-darede.png` junto com os HTMLs, como no app de massagem. Se faltarem, a página degrada para texto sem quebrar.
6. **Netlify** — pode ir para o mesmo site (`/consentimento.html` e `/admin_consentimento.html`) ou um deploy novo. Confirme a Site URL/Redirect no Supabase Auth para o magic link do admin funcionar.
7. **Campaign Code** — quando a Tiemy informar o código da campanha IBM, preencha `CAMPAIGN_CODE` no `admin_consentimento.html`. `Activity Type` e `Activity Name` já vêm preenchidos e podem ser trocados por atividade (palestra, painel, reunião executiva) se a IBM pedir a quebra.

## Operação

- Dispare o e-mail do `textos_para_envio.md` para todos os aprovados.
- Acompanhe pelo relatório: **Participantes / Responderam / Aceitaram / Recusaram / Pendentes**.
- Filtre por "Pendentes", exporte e dispare o lembrete D-3.
- No pós-evento, clique em **Baixar Leads Report IBM**: sai só quem autorizou, no layout `EDIT` com as 14 colunas na ordem exata do modelo, pronto para a Tiemy subir no sistema da IBM.
- O **relatório completo** (com pendentes e recusados) é seu, para controle interno e prova de conformidade. Ele não vai para a IBM.

## Cuidado que vale registrar

Quem não respondeu **não** entra no arquivo da IBM. Ausência de resposta não é consentimento — nem pela LGPD, nem pela política interna da IBM. Se o número de pendentes ficar alto perto do evento, vale um posto de coleta no credenciamento: o mesmo link aberto num tablet resolve, e a resposta é gravada na hora.
