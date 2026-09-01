# Sistema de Gestão de Eventos — CIO Cerrado

## Visão geral

Documenta **comportamento e regra de negócio**, não posição de botão nem layout —
layout muda, regra não.

Conferido contra o código e o banco hospedado em 2026-09-01 — ver
`70-modelo-de-dados.md` até `80-integracoes.md` para o detalhe de cada
apuração. Os trechos marcados como *a confirmar* seguem dependendo do
organizador, não de mais leitura de código.

---

## 1. Para que serve

O sistema substitui o conjunto de planilhas soltas e scripts avulsos que
sustentavam a operação do CIO Cerrado, cobrindo o ciclo inteiro de um evento:

```
Inscrição (Sympla)
  → Contrato (Autentique)
    → Hospedagem e rooming
      → Portal do patrocinador (cotas, quartos, mesa redonda, brindes, indicação de CIO)
        → Jantares
          → Check-in
```

Não substitui o Sympla nem o Autentique: consome os dois e organiza tudo o que
vem depois deles.

## 2. Tipos de evento

O sistema é multi-evento. `eventos.status` aceita três valores:
`rascunho` (invisível ao público — ver RLS em `70-modelo-de-dados.md`),
`aberto`, `encerrado`. **Responde a uma pergunta represada:** existe, sim,
estado de evento encerrado — não é exclusão, é mudança de status; não
verificado se a lista de eventos do admin esconde os encerrados por padrão.

| Tipo | Ciclo | Etapas que se aplicam |
|---|---|---|
| **Evento grande** (junho, resort) | longo, meses | todas: contrato, rooming, transfer, acompanhante, mesa redonda, brindes, check-in |
| **Jantar / evento menor** | curto | curadoria de convidados, confirmação de presença, check-in — **sem `evento_id`, entidade própria** (ver `50-jantares.md`) |

**Regra confirmada:** jantar não tem rooming nem transfer porque a tabela
`jantares` nem se conecta a `reservas`/`quartos` — não é uma etapa
"desativada" na tela, é ausência estrutural no schema.

## 3. Atores

| Ator | Onde entra | O que faz |
|---|---|---|
| **Organizador** (admin) | `admin.html` | acesso total; aprova, decide, dispara |
| **Staff** | `admin.html` (restrito no servidor) e `checkin.html` | mesmas 17 abas visíveis, mas 81 das 111 funções `admin_*` exigem admin especificamente — ver `10-admin.md` |
| **Patrocinador** | `portal.html` | gerencia a própria cota; múltiplos usuários por empresa, criados pelo admin |
| **CIO convidado** | `rooming.html` | dados próprios, acompanhante, filho, transfer |

**Regra confirmada:** o patrocinador não é um login único —
`usuarios_patrocinador` não tem limite de linhas por `patrocinador_id`, todos
enxergando os mesmos dados via `meus_patrocinadores()`.

**Achado que muda a leitura de "papel":** não há RLS de tabela alcançável
por nenhum papel de cliente (zero `GRANT` em tabela/view para
`anon`/`authenticated`). "Papel" aqui significa inteiramente checagem dentro
de função `SECURITY DEFINER` — ver `70-modelo-de-dados.md`.

## 4. Mapa de telas

Base publicada: `https://ciocerrado.netlify.app/gestao/`

| Tela | Parâmetro de evento | Público | Abas/seções reais |
|---|---|---|---|
| `admin.html` | `?evento=` (cabeçalho) | organizador, staff | **17 abas** — Painel, Acompanhamento, Aprovações, Cadastro, Quartos, Organização, Etiquetas, Brindes, Sessões, Atividades, Relatórios, Financeiro, Estrutura, Patrocinadores, Pesquisa, Prospecção, Preços, Equipe |
| `portal.html` | `?evento=` | patrocinador | **7 abas** — Quartos, Mesa redonda, Indicações, Brindes, Convidados, Financeiro, Manual |
| `rooming.html` | `?evento=` | CIO convidado | trilha Inscrição → Contrato → Hospedagem; tela de autocadastro para quem ainda não tem inscrição |
| `checkin.html` | `?evento=` (padrão `cerrado2027`), `?jantar=`, `?local=` | staff | busca por nome **ou leitura de QR** (câmera do celular) |
| `jantares.html` | não usa (jantar é entidade própria) | organizador, staff | **3 abas** — Agenda, Sondagem, Estatísticas |

**Correção ao rascunho:** `checkin.html` lê parâmetro de evento sim, só que
com padrão sensato (`cerrado2027`) quando ausente — a frase "não usa
`?evento=`" estava imprecisa.

Detalhe de cada tela nos arquivos `10` a `50`.

## 5. Arquitetura e ambiente

- **Banco:** Supabase / Postgres. Schema `gestao`, mesmo projeto do sistema de
  agendamento de massagem. **36 tabelas, 8 views** (não "aproximadamente 25").
- **Cuidado crítico:** o schema `public` pertence a outro sistema e tem tabelas
  de nome idêntico (`eventos`, `participantes`, `reservas`, `admins`). Nada no
  sistema de gestão pode ler ou escrever no `public`.
- **Acesso:** nenhum papel de cliente tem `GRANT` de tabela/view — todo
  acesso é por função `SECURITY DEFINER`, que checa papel na primeira linha.
  RLS existe no banco mas é hoje inatingível por essa razão — ver
  `70-modelo-de-dados.md`.
- **Autenticação:** magic link, com opção de criar senha — confirmado em
  todas as quatro telas de usuário final.
- **E-mail:** Resend, com dois caminhos de disparo de comportamento
  diferente entre si (um respeita ambiente de teste, o outro não) — ver
  `80-integracoes.md`. **Contrato:** Autentique, por consulta periódica, não
  webhook. **Inscrição:** Sympla, por API agendada e por importação manual de
  arquivo — os dois coexistem.
- **Deploy:** Netlify, publicado de uma pasta `_site` montada por script.
- **Front:** design system próprio (`assets/design-system.js`), sem framework.

## 6. Princípios que valem para o sistema inteiro

Estes quatro se aplicam a qualquer módulo, atual ou futuro:

1. **Decisão sensível é humana.** Confirmado na prática: a aba Acompanhamento
   (`admin.html`) prepara e-mail de cobrança mas só envia com clique explícito
   por pessoa — nunca "cobrar todos". Única exceção acordada: o primeiro
   aviso de ausência por WhatsApp no dia do evento (ainda não disponível — ver
   `60-modulos-previstos.md`), que seria operacional.
2. **Isolamento entre patrocinadores é falha crítica.** Auditado nesta
   apuração: das 21 funções `patro_*` chamadas por `portal.html`, 19 checam
   `_exige_patrocinador` explicitamente; as 2 que não checam devolvem só dado
   agregado do evento, sem informação de empresa. Nenhuma rota de contorno
   encontrada nas funções client-facing — ver `70-modelo-de-dados.md`.
3. **Nada se perde por preenchimento parcial.** Confirmado parcialmente: o
   formulário de rooming recarrega o que já foi salvo, mas não há rascunho
   de campo-a-campo entre uma tecla e outra — ver `30-area-cio.md`.
4. **Cada dado tem um dono.** *(A confirmar: como o sistema trata edição
   concorrente do mesmo registro — não encontrado mecanismo de lock nem de
   "última edição vence com aviso" nesta apuração.)*

## 7. Etapas acompanhadas

O que a aba **Acompanhamento** de `admin.html` mede de verdade — ver
`v_pendencias_fatos` em `70-modelo-de-dados.md` — são estas oito etapas:

- inscrição aprovada
- contrato assinado (participante e patrocinador, separadamente)
- hospedagem preenchida
- fatura paga
- presença confirmada (mesa redonda/jantar do evento grande)
- convidados de mesa/jantar escolhidos pelo patrocinador
- indicação de CIO feita
- brindes definidos
- quartos preenchidos

Etapas que não se aplicam ao tipo de evento simplesmente não são geradas —
jantar avulso, sem `evento_id`, não entra em nenhuma dessas uniões.

**Isto não é mais módulo previsto — é a aba Acompanhamento, em produção.** Ver
`60-modulos-previstos.md`.

## 8. Como esta documentação está organizada

Um arquivo por área, para que uma mudança em um módulo altere um arquivo só —
documento único vira documento desatualizado.

Índice completo, convenções e regra de manutenção em `README.md`.

---

## A confirmar com o organizador

- Comportamento de sessão expirada: o usuário perde o que digitou? (não
  encontrado tratamento específico em nenhuma das quatro telas de usuário
  final)
- **Trilha de auditoria:** a tabela `auditoria` existe no schema, mas só uma
  função grava nela (`admin_disparar_cobranca`) e está vazia em produção; não
  há tela que a exiba. É para expandir, ou ficou como esqueleto de uma ideia
  que não avançou?
- Se a lista de eventos do admin esconde `status='encerrado'` por padrão ou
  mostra tudo permanentemente.
- Papéis existentes hoje são exatamente quatro, ou há nível intermediário —
  a divisão real encontrada (81 de 111 funções admin-only) sugere uma
  distância grande entre "admin" e "staff"; vale confirmar se é a intenção
  ou se staff deveria enxergar mais do que enxerga hoje.
- Como o sistema trata edição concorrente do mesmo registro por duas pessoas
  ao mesmo tempo (ex.: dois usuários do mesmo patrocinador).
