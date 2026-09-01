# Documentação do sistema de gestão de eventos — CIO Cerrado

Documentação funcional do sistema. Descreve **o que o sistema faz e por quais
regras**, para quem opera, para quem vai mexer no código e para o próprio
organizador conferir se o comportamento continua sendo o combinado.

Vive no repositório do sistema, versionada junto com ele.

---

## Índice

| Arquivo | Área |
|---|---|
| `00-visao-geral.md` | escopo, atores, telas, arquitetura, princípios |
| `10-admin.md` | painel do organizador e do staff |
| `20-portal-patrocinador.md` | portal do patrocinador |
| `30-area-cio.md` | área do CIO convidado (rooming) |
| `40-checkin.md` | check-in |
| `50-jantares.md` | jantares e curadoria |
| `60-modulos-previstos.md` | especificado, ainda não construído |
| `70-modelo-de-dados.md` | schema `gestao`: tabelas, relações, políticas |
| `80-integracoes.md` | Sympla, Autentique, Resend, Supabase, Netlify |
| `CHANGELOG.md` | o que mudou no sistema, por data |

---

## Regra de manutenção

**Mudança de comportamento e mudança de documentação andam na mesma alteração.**
Doc atualizada depois é doc que não é atualizada.

Na prática, ao mexer no sistema:

1. Se a mudança altera uma regra descrita aqui, edite o arquivo da área na mesma
   branch, junto com o código.
2. Se a mudança cria ou remove tela, aba ou campo, atualize também o mapa de
   telas em `00-visao-geral.md`.
3. Se a mudança toca o schema, atualize `70-modelo-de-dados.md`.
4. Registre a mudança em `CHANGELOG.md`, em uma linha, com data.
5. Se um módulo de `60-modulos-previstos.md` foi construído, mova o conteúdo
   para o arquivo de área correspondente e tire de lá.

## Convenções de escrita

- **Comportamento e regra, não interface.** "O envio exige confirmação
  individual" sobrevive a redesenho; "clique no botão do canto" não.
- **Nada de regra inventada.** O que não estiver claro vai para a seção
  *A confirmar com o organizador*, no fim de cada arquivo, e fica lá até ser
  respondido. Suposição escrita como fato é pior que lacuna declarada.
- **Módulo não construído se marca "previsto, não disponível"**, para ninguém
  procurar tela que não existe.
- **Nenhuma credencial, chave ou token nesta pasta.** Integrações descrevem o
  fluxo e citam o nome da variável de ambiente, nunca o valor.
- Um arquivo por área. Arquivo que passa a tratar de duas áreas vira dois.

## Estado atual

Sistema finalizado e em fase de testes. As seções *A confirmar* ainda são
numerosas — é esperado nesta etapa, e a redução delas é a medida de progresso
desta documentação.
