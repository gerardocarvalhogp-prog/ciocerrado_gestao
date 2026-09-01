# Modelo de dados — schema `gestao`

Documenta a estrutura do banco no nível de **o que cada coisa representa e quais
regras o banco garante** — não o DDL, que fica no próprio repositório de
migrações e envelhece se for copiado para cá.

---

## Onde o sistema vive

- Supabase / Postgres.
- Schema **`gestao`**, dentro do mesmo projeto Supabase do sistema de
  agendamento de massagem.
- Aproximadamente **25 tabelas**, com RLS e views de leitura consolidada.

### Cuidado crítico com o schema `public`

O schema `public` do mesmo projeto pertence a **outro sistema** e contém tabelas
com nomes idênticos aos daqui: `eventos`, `participantes`, `reservas`, `admins`.

Foi exatamente essa colisão que motivou o schema próprio.

**Regra:** nenhuma query, view, função ou política do sistema de gestão pode ler
ou escrever no `public`. Toda referência é qualificada com `gestao.`. Qualquer
alteração que crie dependência entre os dois schemas é erro, não otimização.

---

## Entidades principais

*A confirmar contra o schema: nomes exatos das tabelas, cardinalidades e campos.
O que segue é o modelo conceitual acordado.*

| Entidade | Representa | Notas |
|---|---|---|
| Evento | evento grande ou jantar | eixo de quase toda consulta |
| Participante | pessoa inscrita e aprovada | origem no Sympla |
| Empresa patrocinadora | quem contratou cota | 1 empresa, N usuários de acesso |
| Cota | nível de patrocínio | define limites: quartos, vagas de mesa, participantes |
| Usuário de acesso | login | vinculado a papel e, quando patrocinador, a uma empresa |
| Contrato | documento de assinatura | status espelha o Autentique |
| Quarto / ocupação | hospedagem | ocupantes podem ser CIO, acompanhante, filho ou pessoal do patrocinador |
| Acompanhante / filho | dependentes do CIO | geram cobrança adicional |
| Transfer | embarque | origem GYN ou BSB, ida e volta |
| Mesa redonda | mesa por patrocinador, por dia | vagas conforme a cota |
| Jantar | evento menor com um patrocinador | curadoria própria |
| Presença / check-in | registro de chegada | por evento; por atividade é módulo previsto |
| Brinde | item do patrocinador | |
| Lançamento financeiro | cota, fatura adicional | |

---

## Regras garantidas pelo banco

*A confirmar quais destas são constraint no banco e quais são validação apenas
no front — a diferença importa: o que só está no front não protege importação,
script nem API.*

- Um patrocinador só acessa linhas da própria empresa (RLS).
- Vagas de mesa redonda não podem exceder a cota da empresa.
- Um convidado não se repete na mesma mesa em dias diferentes.
- Ocupação de quarto não excede a capacidade do quarto.
- Check-in duplicado da mesma pessoa no mesmo evento não gera dois registros.
- Etapas inaplicáveis ao tipo de evento não existem como pendência.

---

## Políticas de acesso (RLS)

O isolamento entre patrocinadores é sustentado por RLS, não por filtro no front.
Filtro de tela é conveniência; a garantia é do banco.

Perfis e alcance:

| Perfil | Alcance |
|---|---|
| Organizador | tudo, todos os eventos |
| Staff | subconjunto operacional do evento corrente |
| Patrocinador | apenas a própria empresa, apenas os eventos em que ela tem cota |
| CIO | apenas os próprios dados e dependentes |

*A confirmar: alcance exato do staff, e se o patrocinador enxerga eventos
passados.*

---

## Views

Existem views de leitura consolidada, usadas para montar listas e exportações
sem replicar joins no front.

*A confirmar: quais são, o que cada uma consolida, e se alguma é usada como base
das exportações em Excel.*

---

## A confirmar com o organizador / no schema

- Lista real das 25 tabelas com uma linha de descrição cada.
- Quais regras acima são constraint e quais são validação de tela.
- Estratégia de exclusão: registro apagado de fato ou marcado como inativo?
- Há trilha de auditoria (tabela de log de alterações)?
- Como o schema trata um participante que vai a mais de um evento — mesmo
  registro reaproveitado ou um por evento?
