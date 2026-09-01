# Sistema de Gestão de Eventos — CIO Cerrado

## Visão geral

Documenta **comportamento e regra de negócio**, não posição de botão nem layout —
layout muda, regra não.

Escrito a partir das decisões de projeto. Os trechos marcados como *a confirmar*
dependem de verificação no código, no schema ou na tela.

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

O sistema é multi-evento. O evento é o eixo de tudo — quase toda tela recebe o
evento no parâmetro `?evento=`, e o admin seleciona o evento ativo no cabeçalho.

| Tipo | Ciclo | Etapas que se aplicam |
|---|---|---|
| **Evento grande** (junho, resort) | longo, meses | todas: contrato, rooming, transfer, acompanhante, mesa redonda, brindes, check-in |
| **Jantar / evento menor** | curto | contrato (quando há), curadoria de convidados, confirmação de presença, check-in |

**Regra:** etapa que não se aplica ao tipo de evento não aparece na interface e
não conta como pendência. Jantar não tem rooming nem transfer.

## 3. Atores

| Ator | Onde entra | O que faz |
|---|---|---|
| **Organizador** (admin) | `admin.html` | acesso total; aprova, decide, dispara |
| **Staff** | `admin.html` (restrito) e `checkin.html` | operação do dia; acesso limitado |
| **Patrocinador** | `portal.html` | gerencia a própria cota; múltiplos usuários por empresa |
| **CIO convidado** | `rooming.html` | dados próprios, acompanhante, filho, transfer |

**Regra:** o patrocinador não é um login único. Uma empresa patrocinadora pode
ter vários usuários com acesso, todos enxergando os mesmos dados da empresa e
nada de outra empresa.

## 4. Mapa de telas

Base publicada: `https://ciocerrado.netlify.app/gestao/`

| Tela | Parâmetro de evento | Público | Conteúdo |
|---|---|---|---|
| `admin.html` | sim (cabeçalho) | organizador, staff | Visão geral, Cadastro & aprovação, Logística, Financeiro, Divulgação, Equipe |
| `portal.html` | `?evento=` | patrocinador | Quartos, Mesa redonda, Indicar CIO, Brindes, Financeiro |
| `rooming.html` | `?evento=` | CIO convidado | acompanhante, filho, transfer |
| `checkin.html` | não usa | staff | check-in do dia |
| `jantares.html` | não usa | organizador | jantares e curadoria |

Detalhe de cada tela nos arquivos `10` a `50`.

## 5. Arquitetura e ambiente

- **Banco:** Supabase / Postgres. O sistema vive no schema `gestao`, dentro do
  mesmo projeto Supabase do sistema de agendamento de massagem.
- **Cuidado crítico:** o schema `public` pertence a outro sistema e tem tabelas
  de nome idêntico (`eventos`, `participantes`, `reservas`, `admins`). Nada no
  sistema de gestão pode ler ou escrever no `public`.
- **Acesso:** RLS no banco; views para leitura consolidada.
- **Autenticação:** magic link, com opção de criar senha.
- **E-mail:** Resend. **Contrato:** Autentique. **Inscrição:** Sympla.
- **Deploy:** Netlify.
- **Front:** design system próprio, já passado por reforma de UX (mobile, cores
  da marca). A identidade visual herda a marca do site institucional
  (ciocerrado.com.br) — não há tema próprio do sistema.

## 6. Princípios que valem para o sistema inteiro

Estes quatro se aplicam a qualquer módulo, atual ou futuro:

1. **Decisão sensível é humana.** Cobrança, convite e disparo em massa: o
   sistema prepara, mostra e registra; quem confirma o envio é o organizador.
   Única exceção acordada: o primeiro aviso de ausência por WhatsApp no dia do
   evento, que é operacional.
2. **Isolamento entre patrocinadores é falha crítica.** Um patrocinador jamais
   vê dado de outro — nem por URL manipulada, nem em exportação, nem em lista de
   mesa redonda.
3. **Nada se perde por preenchimento parcial.** O CIO e o patrocinador voltam
   várias vezes ao mesmo formulário; o estado salvo precisa ser explícito.
4. **Cada dado tem um dono.** O que o patrocinador preenche não é sobrescrito
   pelo admin sem registro, e vice-versa. *(A confirmar: como o sistema trata
   edição concorrente do mesmo registro.)*

## 7. Etapas acompanhadas

O que o sistema considera "pendência" por perfil:

**CIO convidado**
- inscrição aprovada
- contrato assinado
- rooming preenchido
- acompanhante e filho informados
- transfer escolhido
- fatura adicional quitada
- confirmação de jantar ou de mesa redonda

**Patrocinador**
- contrato assinado
- participantes cadastrados até o limite da cota
- ocupantes dos quartos definidos
- convidados de mesa redonda escolhidos
- indicação de CIO
- brindes informados
- confirmação dos convidados de jantar
- pagamento da cota

A tela que consolida e cobra essas pendências é **módulo previsto, ainda não
disponível** — ver `60-modulos-previstos.md`.

## 8. Como esta documentação está organizada

Um arquivo por área, para que uma mudança em um módulo altere um arquivo só —
documento único vira documento desatualizado.

Índice completo, convenções e regra de manutenção em `README.md`.

---

## A confirmar com o organizador

- Comportamento de sessão expirada: o usuário perde o que digitou?
- Há trilha de auditoria (quem alterou o quê e quando) visível na interface, ou
  só no banco?
- O sistema permite arquivar/encerrar um evento passado, ou eventos antigos
  ficam permanentemente na lista?
- Papéis existentes hoje são exatamente quatro (organizador, staff,
  patrocinador, CIO) ou há níveis intermediários?
