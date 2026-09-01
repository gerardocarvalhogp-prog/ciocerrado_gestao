# Jantares — `jantares.html`

Jantares e eventos menores. Ciclo curto, com etapas próprias. **Não usa
`?evento=` na URL.**

---

## Modelo

Cada jantar tem **um patrocinador**. O patrocinador oferece o jantar; a
organização escolhe quem senta à mesa.

A curadoria da lista é a atividade central — mais do que a logística. Ela cruza
a base de cadastro do CIO Cerrado com o perfil comercial do patrocinador,
calcula aderência e seleciona os executivos.

O processo de curadoria tem procedimento próprio, documentado à parte (skill
`jantares-cio-cerrado`). Não é reconstruído aqui.

---

## Regra crítica: o que o patrocinador recebe

A lista de validação enviada ao patrocinador contém:

- empresa
- segmento
- cidade
- estado
- aderência

E **não contém**:

- nome dos executivos
- justificativa interna da seleção

O patrocinador valida perfis de empresa, não pessoas. Vazar nome de executivo na
etapa de validação quebra a relação com a base.

---

## Fluxo

1. Cadastro do jantar: patrocinador, data, local, capacidade.
2. Curadoria: seleção dos convidados a partir da base, por aderência.
3. Validação com o patrocinador (lista sem nomes).
4. Convite aos executivos selecionados.
5. Confirmação de presença.
6. Check-in no dia.

**Regra:** o convite é decisão humana. O sistema prepara a lista e o texto;
quem dispara é o organizador.

*A confirmar: quanto desse fluxo está no sistema hoje e quanto ainda passa por
planilha e Sympla.*

---

## O que não se aplica

Jantar não tem rooming, transfer, acompanhante, filho nem mesa redonda. Essas
etapas não devem aparecer nem contar como pendência.

Reaproveita, porém, a lógica de afinidade e porte usada na alocação das mesas
redondas do evento grande.

---

## A confirmar com o organizador

- O jantar é cadastrado como um "evento" da mesma tabela do evento grande, ou
  tem entidade própria?
- Um executivo pode ser convidado para dois jantares diferentes? Há trava?
- A confirmação de presença do convidado é por link, e-mail ou Sympla?
- O patrocinador do jantar tem acesso ao portal, ou o jantar é operado só pelo
  admin?
- Existe registro de quem foi convidado e não compareceu, para uso em curadorias
  futuras?
