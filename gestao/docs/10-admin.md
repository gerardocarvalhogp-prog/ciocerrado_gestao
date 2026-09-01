# Painel do organizador e do staff — `admin.html`

Tela central do sistema. O organizador tem acesso total; o staff tem acesso
restrito a um subconjunto das seções.

O **evento ativo é selecionado no cabeçalho** e condiciona tudo o que aparece
abaixo. Trocar o evento troca o conteúdo de todas as seções.

---

## Seções

### Visão geral

Painel de entrada. Situação do evento selecionado em números: inscritos,
contratos assinados, rooming preenchido, patrocinadores por cota, pendências
abertas.

*A confirmar: quais indicadores exatos aparecem e se algum deles é clicável para
a lista correspondente.*

**Regra de leitura:** a Visão geral não é fonte de verdade para conferência — é
resumo. Conferência se faz nas listas e nas exportações.

### Cadastro & aprovação

Onde entram e são validadas as pessoas e as empresas.

- Inscritos vindos do **Sympla**, com aprovação pelo organizador.
- Cadastro de patrocinadores e da cota contratada.
- Cadastro dos usuários de acesso do patrocinador (mais de um por empresa).
- Envio de contrato via **Autentique** e acompanhamento do status de assinatura.

**Regras:**
- A inscrição só vira participante depois de aprovada. Inscrição não aprovada
  não gera contrato, não ocupa quarto e não conta em cota.
- O status do contrato é reflexo do Autentique, não é editado à mão.
  *(A confirmar: existe sobrescrita manual para o caso de contrato assinado
  fora do fluxo?)*

### Logística

Tudo que envolve estar fisicamente no evento.

- **Rooming list**: quartos, ocupantes, tipo de acomodação.
- **Acompanhantes e filhos**, com a cobrança adicional decorrente.
- **Transfer**: origem (GYN / BSB), ida e volta.
- **Mesa redonda**: mesas por patrocinador, cota de convidados por mesa,
  alocação dos convidados.
- **Crachás e etiquetas**: geração a partir da lista consolidada.

**Regras herdadas da operação, que o sistema precisa preservar:**
- Cota de convidados por mesa segue a hierarquia de patrocínio, preenchida na
  ordem Esmeralda → Diamante → Platina → Ouro → Prata.
- Quando o perfil do convidado traz o nome de um patrocinador, ele vai para a
  mesa desse patrocinador.
- Nenhum convidado se repete na mesma mesa em dias diferentes.
- Órgãos públicos não entram nas cotas mais altas, salvo indicação explícita do
  próprio patrocinador — orçamento público não é receita e não vale para
  ranking de porte.
- Menores de 21 anos não recebem crachá.

*A confirmar: quanto dessa lógica está implementada no sistema e quanto ainda
roda por script fora dele.*

### Financeiro

- Valor da cota por patrocinador e situação de pagamento.
- Faturas adicionais do CIO (acompanhante, filho, noite extra).
- *A confirmar: o sistema emite cobrança, ou apenas registra o que foi
  combinado e pago?*

### Divulgação

*A confirmar: escopo desta seção — logos de patrocinador, material de
divulgação, listas para o app do evento, ou comunicação com a base?*

### Equipe

Gestão de quem tem acesso ao painel e com qual permissão.

**Regra:** o staff é contratado para o dia e opera em pé, com fila na frente.
O acesso dele é deliberadamente restrito: ele não deve conseguir alterar
cadastro, cota, valor ou alocação. *(A confirmar: lista exata do que o staff
enxerga.)*

---

## Exportações

O painel gera arquivos que a operação consome fora do sistema (Excel,
etiquetas, listas de importação para o app do evento).

**Regra:** toda exportação precisa ser conferida abrindo o arquivo — botão que
não dá erro não significa arquivo correto. Conferir sempre: acentuação, ordem,
registros sem e-mail, e se a exportação respeita o evento selecionado.

*A confirmar: lista completa das exportações disponíveis e o formato de cada
uma.*

---

## O que este painel ainda não faz

- Não há tela de acompanhamento de pendências com tempo de espera e histórico de
  cobrança.
- Não há disparo de e-mail de cobrança.

Ambos são módulo previsto — ver `60-modulos-previstos.md`.

---

## A confirmar com o organizador

- Indicadores exatos da Visão geral e se levam à lista detalhada.
- Divisão precisa de permissões entre organizador e staff.
- Escopo da seção Divulgação.
- Quais regras de mesa redonda estão no sistema e quais continuam em script.
- Se o Financeiro emite cobrança ou apenas registra.
- Comportamento ao trocar de evento com formulário aberto pela metade.
