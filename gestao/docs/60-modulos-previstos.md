# Módulos previstos, ainda não disponíveis

Nada aqui existe na interface. Registrado como especificação para que o time não
procure tela que não foi construída — e para que a construção não invente regra.

---

## 1. Acompanhamento e cobrança de pendências

**Prioridade de construção.** É o buraco mais sentido hoje: o sistema coleta,
mas não mostra quem está atrasado nem ajuda a cobrar.

### O que a tela mostra

Por pendência, por pessoa ou empresa:

- qual etapa está aberta
- há quanto tempo está aberta (tempo de espera)
- atraso em relação ao prazo, quando existe prazo
- data da última cobrança
- quantas cobranças já foram feitas

Vale para os dois perfis (CIO e patrocinador) e para os dois tipos de evento
(grande e jantar). Etapas que não se aplicam ao tipo de evento não aparecem.

### Como a cobrança funciona

**Regra central: a cobrança é decisão humana.** Não há disparo automático.

1. O sistema identifica a pendência e prepara o e-mail.
2. O organizador abre a tela de conferência e revisa o conteúdo.
3. O organizador confirma o envio, pessoa a pessoa.
4. O sistema registra o envio e incrementa o contador de cobranças.

Não existe "cobrar todos". O que o sistema faz é tornar o disparo individual
rápido, não removê-lo.

*A confirmar: os textos de cobrança são modelos editáveis? Passam pela Fernanda
antes, por saírem com a voz da comunicação do CIO Cerrado?*

---

## 2. Presença, QR code e WhatsApp

**Exclusivo do evento grande de junho.**

### Atividades e presença

- Atividades cadastradas por evento, tipicamente duas por dia: manhã e
  pós-almoço.
- Presença registrada por atividade, não só a chegada ao evento.

### QR code

- Crachá com QR **opaco** (não legível a olho nu, sem dado exposto no impresso).
- Leitura pela câmera do celular do staff.
- **Mesmo leitor** para chegada e para presença por atividade — o que muda é o
  contexto, que precisa estar explícito na tela para quem está bipando.

### WhatsApp

Integração com a **API oficial** do WhatsApp para quem não chegou.

| Momento | Mensagem | Disparo |
|---|---|---|
| ~15 min de atraso | leve, operacional ("já estamos começando") | automático |
| 1–2 h de atraso | pessoal, de cuidado | só com confirmação do organizador |

O primeiro aviso é a **única exceção** à regra de decisão humana em todo o
sistema, e é exceção por ser operacional e de baixo risco.

### Dependências externas — começar cedo

- Verificação da conta WhatsApp Business.
- Aprovação de template de mensagem pela Meta.

Ambas dependem de terceiro e têm prazo próprio. São o caminho crítico deste
módulo, não a programação.

---

## 3. Integração com o app do evento

### Como é hoje

Por arquivo. Dois modelos exportados do sistema — **usuários** e **empresas** —
importados manualmente no app.

Regras já estabelecidas do processo manual:
- registros sem e-mail são excluídos da importação
- o identificador de empresa é conferido contra a lista de empresas já
  cadastradas na plataforma
- registros novos entram ao final do arquivo

### O que se quer

O app é de um parceiro externo, e o que não existe pode ser construído —
inclusive envio automático e retorno de dados do app para o sistema.

**A definição que destrava tudo é a chave de identificação estável entre os dois
lados.** Sem um identificador que sobreviva a mudança de nome, de e-mail e de
empresa, qualquer integração vira reconciliação manual — o problema que se quer
eliminar.

Enquanto essa chave não estiver acordada com o parceiro, não vale construir a
integração.

*A confirmar: o que o parceiro oferece hoje de API, e qual identificador ele
consegue aceitar e devolver.*

---

## A confirmar com o organizador

- Ordem de construção dos três módulos e se algum pode esperar o próximo ciclo.
- Prazos por etapa que alimentam o cálculo de atraso do módulo de cobrança.
- Quem, além do organizador, pode confirmar um disparo de cobrança.
- Se a presença por atividade precisa de relatório próprio ou entra no relatório
  geral do evento.
