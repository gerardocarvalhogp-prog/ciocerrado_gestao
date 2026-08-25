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

O `gestao` hospedado ainda tem **dados de teste** (8 participantes, 4
perfis, 5 sessões, 0 faturas). O que está em produção nesse projeto é o
`public`, do sistema de massagem.

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
nomes de parâmetro batendo. O front pode ser publicado contra o banco
hospedado como está.

---

## Como aplicar um arquivo desta pasta

```bash
supabase db query --linked -f supabase/remoto/NN-arquivo.sql
```

Um arquivo por vez, na ordem numérica. Cada um é cirúrgico: mexe só no
que o cabeçalho diz.

`00-estado-anterior.sql` é o dump das funções **antes** de 02 e 03 —
é o rollback, não fonte para editar.

## Estado das correções

| arquivo | o que faz | aplicado no remoto |
|---|---|---|
| `01-fechar-anon.sql` | tira `execute` de 101 funções admin do papel `anon` | **sim** — conferido em 24/08: anon executa só `is_staff`, `meus_patrocinadores` e `part_autocadastro`, e o default privilege de funções não tem mais `anon` nem `public` |
| `02-fatura-complementar.sql` | fatura nova cobra a diferença, não o valor cheio | **sim** — 24/08 |
| `03-indicacao-e-porte.sql` | indicação no PERFIL ordena a lista; porte deixa de ser ordem alfabética | **sim** — 24/08; retorno conferido com as 6 colunas, `anon` sem execute, e o porte lido dos 4 perfis reais na ordem certa |
| `04-prazo-de-indicacao.sql` | indicação vira reserva; prazo por cota faz a fila andar sozinha | **não** — falta aplicar |

> **O `04` precisa ser aplicado antes de publicar o `admin.html` desta
> leva.** A tela passou a mandar `p_prazo_indicacao` para
> `admin_salvar_cota` e a ler `prazo_indicacao` de `admin_listar_cotas`.
> Sem o `04` no banco, salvar cota quebra.
>
> ```bash
> supabase db query --linked -f supabase/remoto/04-prazo-de-indicacao.sql
> ```

Cada um tem um par versionado em `supabase/migrations/` com o mesmo
corpo, para as duas linhagens não divergirem mais:

- `02` ↔ `20260824102200_fatura_complementar.sql`
- `03` ↔ `20260824102300_indicacao_e_porte.sql`

As duas correções passaram no local (`supabase db reset` com 23
migrations, mais `supabase/tests/04-fatura-complementar.sql`).

Ainda não há tabela de RLS conferida no remoto além do básico: as 29
tabelas do `gestao` estão todas com RLS ligada.

## A regra da indicação, como ficou decidida

O `03` implementou a indicação como **ordem** — o indicado subia ao topo
da lista de quem indicou, mas continuava visível para as outras empresas.
O `04` fecha a regra: indicação é **reserva**, e o que a solta é o prazo.

1. Enquanto a cota de quem indicou está no prazo, o convidado indicado
   **não aparece** para mais ninguém.
2. A vez passa para a cota seguinte quando a anterior termina de escolher
   (encerra, passa a vez, enche a mesa) **ou** quando o prazo dela vence
   — o que vier primeiro.
3. Escolhido, o convidado fica preso naquela mesa: some da lista de
   todos. Isso já funcionava.
4. Prazo vencido sem escolha: a reserva cai e ele volta para a lista
   geral.

Vencer o prazo custa a fila e as reservas, **não** o direito de escolher
entre quem estiver livre.

A reserva vale nos dois sentidos da fila: o convidado indicado pela Ouro
resiste à Esmeralda, que escolhe antes de todo mundo. Se valesse só de
cima para baixo, não valeria nada — é o caso que
`supabase/tests/05-reserva-e-prazo.sql` cobre.

O prazo fica em `cotas.prazo_indicacao`, uma data por cota, editável na
aba **Estrutura** do admin. Cota sem prazo se comporta como antes: segura
a vez até encerrar ou passar.
