# Esta pasta está encerrada

Os arquivos daqui foram o caminho de correção enquanto havia **duas**
implementações do sistema: as migrations escritas à mão e o schema
`gestao` do projeto hospedado, que tinha seguido outro caminho.

Isso acabou em 24/08/2026. O hospedado virou a origem, e
`supabase/migrations/20260824110100_baseline_hospedado.sql` é o dump
dele. A partir daí:

```bash
supabase db reset    # reproduz o hospedado do zero, local
supabase db push     # aplica no hospedado o que vier depois do baseline
```

**Não crie arquivo novo aqui.** Correção entra como migration.

## Por que existia

O hospedado tinha sido montado direto no SQL Editor e estava, em pontos,
à frente das migrations. As duas linhagens expunham a mesma API — as 92
RPCs que as telas chamam batiam nos dois lados — mas por dentro eram
implementações diferentes: 33 funções locais chamavam `exigir_admin`,
`evento_id_por_slug` e `cap_tipo`, helpers que o hospedado nem tem (lá a
mesma checagem é `_exige_admin`). Onze funções existiam só de um lado.

O custo era cobrado em toda mudança: cada correção escrita duas vezes, e
o `db reset` testando um sistema que não era o que estava no ar.

## O que foi aplicado por aqui, antes do encerramento

| arquivo | o que fez |
|---|---|
| `01-fechar-anon.sql` | tirou `execute` de 101 funções administrativas do papel `anon` |
| `02-fatura-complementar.sql` | fatura nova passa a cobrar a diferença, não o valor cheio |
| `03-indicacao-e-porte.sql` | indicação no PERFIL ordena a lista; porte deixa de ser ordem alfabética |
| `04-prazo-de-indicacao.sql` | indicação vira reserva, com prazo por cota |
| `05-janela-por-cota.sql` | janela relativa ("48h depois que a anterior encerrar"); prazo vencido tira da escolha |
| `06-checkin-desfazer-auditavel.sql` | desfazer check-in grava quem desfez e falha quando não desfaz nada |

Todos estão dentro do baseline. `00-estado-anterior.sql` é o dump das
funções antes de 02 e 03 — serve de rollback histórico, não de fonte.

O `06` foi a única coisa em que a linhagem local estava na frente, e por
isso subiu antes do dump: a versão do hospedado devolvia `{"ok": true}`
mesmo sem ter desfeito nada, e não guardava o autor.

## A regra da indicação, como ficou

1. Enquanto a cota de quem indicou está na janela dela, o convidado
   indicado **não aparece** para mais ninguém.
2. A vez passa para a cota seguinte quando a anterior termina de escolher
   (encerra, passa a vez, enche a mesa) **ou** quando a janela dela vence
   — o que vier primeiro.
3. Escolhido, o convidado fica preso naquela mesa: some da lista de
   todos.
4. Janela vencida sem escolha: a reserva cai e ele volta para a lista
   geral.
5. Quem perdeu a janela está **fora daquela sessão** — não escolhe nem
   quem sobrou.

A janela é relativa: cada cota tem `janela_horas`, contadas do fim da
anterior. A primeira começa em `eventos.escolha_abre_em`. Há um teto
absoluto opcional por cota (`prazo_indicacao`); vale o que vier primeiro
entre os três. Âncora vazia = nada expira.

A reserva vale nos dois sentidos da fila: o indicado pela Ouro resiste à
Esmeralda, que escolhe antes de todo mundo. Se valesse só de cima para
baixo, não valeria nada — é o caso central de
`supabase/tests/05-reserva-e-prazo.sql`.
