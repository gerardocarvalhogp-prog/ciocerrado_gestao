# O banco hospedado seguiu outro caminho

**Não rode `supabase db push` contra o projeto `jlvcjqfrsxxexflvwbvn`.**

## O que foi medido

Dump do schema `gestao` remoto, em 24/08/2026:

| | remoto | local (`supabase/migrations/`) |
|---|---|---|
| tabelas | 29 | 29 |
| funções | 132 | 129 |
| histórico de migrations | vazio | 21 |

As 21 migrations locais constam como **não aplicadas** no remoto. Mas o
remoto não é um banco vazio esperando por elas: é uma implementação
completa, aplicada direto no SQL Editor, e em pontos **mais avançada**
que a local.

## Nove funções que só existem no remoto

```
_exige_participante      _garantir_reserva        _recalcular_fechado
admin_gerar_sessoes      admin_registrar_sugestao admin_remover_quartos_livres
admin_remover_sessao     admin_salvar_sessao      part_minha_fatura
```

Gestão de sessões e fatura do participante — funcionalidade que os
arquivos locais não têm.

## Modelos de dados incompatíveis

| assunto | remoto | local |
|---|---|---|
| pesquisa de investimento | chave dentro de `participante_perfil.respostas` (jsonb) | colunas próprias `investimentos`, `dispositivos`, `terceirizados` |
| prospecção | uma tabela `prospeccoes` | duas: `prospeccao_rodadas` + `prospeccao_itens` |

Aplicar as migrations locais por cima **substituiria** funções remotas
por versões que leem um modelo de dados que não existe lá. Não é um
merge; é uma troca de arquitetura.

## O que o front precisa: nada

As 97 RPCs que as cinco telas chamam **existem todas no remoto**, com os
nomes de parâmetro batendo. Inclui as 5 da aba Financeiro escrita nesta
sessão. O front pode ser publicado contra o banco hospedado como está.

## O que vale aplicar no remoto

`01-fechar-anon.sql` — 101 funções administrativas têm `GRANT` explícito
para `anon`, e a chave anon é pública (está nos cinco `.html`). É
correção de permissão, não de lógica: não toca em nenhuma função.

## O que NÃO foi aplicado, e por quê

Dois defeitos confirmados no remoto que envolvem regra de negócio e
ficam para decisão do organizador:

1. **`patro_convidados_disponiveis` ordena só por `empresa, nome`.** A
   primeira camada da regra de alocação — "se o patrocinador indicou a
   pessoa no PERFIL, ela vai para a mesa dele" — não está implementada.

2. **`_recalcular_fatura_participante` cria fatura nova com o valor
   cheio** quando a anterior já foi paga, em vez da diferença. Cobra
   duas vezes o mesmo acompanhante.
