# A linhagem anterior

Estes 25 arquivos **não rodam mais**. Estão fora de
`supabase/migrations/` de propósito: o CLI não os enxerga aqui.

Eles montavam o schema `gestao` do zero, escritos à mão entre 18 e 24 de
agosto de 2026. Em 24/08 o projeto hospedado virou a origem e
`supabase/migrations/20260824110100_baseline_hospedado.sql` — o dump
dele — passou a ser o ponto de partida.

## Por que a troca

Havia duas implementações do mesmo sistema. As duas expunham a mesma
API: as 92 RPCs que as telas chamam existiam nos dois lados, com os
nomes de parâmetro batendo. Por dentro, divergiam:

- 33 funções daqui chamavam `exigir_admin`, `exigir_staff`,
  `evento_id_por_slug` e `cap_tipo` — helpers que o hospedado não tem.
  Lá a mesma checagem é `_exige_admin` / `_exige_staff`.
- 11 funções existiam só de um lado. Gestão de sessões
  (`admin_salvar_sessao`, `admin_gerar_sessoes`) e `part_minha_fatura`
  só existiam no hospedado.
- `checkins.desfeito_por` e a view `v_checkin_esperados` só existiam
  aqui.

Cada correção precisava ser escrita duas vezes — uma migration e um
arquivo em `supabase/remoto/` — e o `db reset` testava um sistema que
não era o publicado.

## Por que guardar

Pelos cabeçalhos. Cada arquivo abre com o porquê da decisão que ele
carrega: a inversão da regra de indicação, a ordem que redefine 47
funções, a trava do `anon`, o preço por faixa etária, a fatura
complementar. O dump preserva os comentários de dentro dos corpos das
funções, mas não essas explicações.

Se algum dia a pergunta for "por que isso é assim", começa aqui.

## O que sobreviveu daqui

`checkin_desfazer`. A versão do hospedado devolvia `{"ok": true}` mesmo
sem ter desfeito nada e não guardava o autor; a daqui fazia as duas
coisas certas. Subiu por `supabase/remoto/06` antes do dump, e está
dentro do baseline.

`v_checkin_esperados` e o resto ficaram para trás — nenhuma função e
nenhuma tela usavam.
