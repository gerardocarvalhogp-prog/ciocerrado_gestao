# Portal do patrocinador — `portal.html?evento=`

Área onde a empresa patrocinadora administra a própria cota. É a face do evento
para quem está pagando por ele: acabamento e clareza aqui valem tanto quanto
função.

Acesso por magic link, com opção de criar senha. **Uma empresa pode ter vários
usuários com login**, todos com a mesma visão dos dados da empresa.

Um **aviso de pendências no topo** mostra o que falta a empresa preencher.

---

## Regra crítica: isolamento

O patrocinador vê exclusivamente os dados da própria empresa. Isso precisa valer
em toda superfície:

- listas e formulários das abas
- URL manipulada com identificador de outra empresa
- resultados de busca
- arquivos exportados
- lista de convidados de mesa redonda e de jantar

Vazamento entre patrocinadores é falha crítica, não cosmética.

---

## Abas

### Quartos

Quartos que a cota dá direito e definição de quem ocupa cada um.

- Tipo de acomodação por quarto.
- Ocupantes, dentro do limite da cota.
- *A confirmar: o patrocinador pode pedir quarto adicional pelo portal, e isso
  gera cobrança automática?*

**Gotcha conhecido da operação:** no processo antigo em planilha, patrocinadores
preenchiam o campo de associação com o **nome da empresa** em vez do número,
agrupando tudo indevidamente. O sistema precisa impedir esse tipo de entrada
livre onde deveria haver seleção.

### Mesa redonda

Vagas de convidado que a cota dá direito e escolha de quem ocupa cada uma.

**Regras:**
- O número de vagas vem da cota (Esmeralda → Prata, em ordem decrescente).
- O patrocinador pode indicar convidados próprios; o restante é alocado pela
  organização por porte e afinidade comercial.
- Indicação do patrocinador tem precedência sobre a alocação automática.
- Depois de o material estar impresso, mudanças são acomodadas alterando o
  mínimo possível das demais mesas.

*A confirmar: o portal mostra ao patrocinador a lista final da mesa dele, e em
que momento ela é liberada.*

### Indicar CIO

Indicação de executivos que o patrocinador quer ver convidados ao evento.

**Regra:** indicação não é convite. Ela entra numa fila de avaliação da
organização e só vira convidado após aprovação. O portal precisa deixar isso
explícito para não criar expectativa com o cliente do patrocinador.

*A confirmar: o patrocinador acompanha o status da indicação (pendente,
aprovada, recusada, inscrita)?*

### Brindes

Registro do brinde que o patrocinador vai distribuir.

*A confirmar: o que é coletado — descrição, quantidade, data de entrega,
dimensões, imagem? Há prazo limite?*

### Financeiro

Valor da cota, situação de pagamento e eventuais adicionais.

*A confirmar: há nota fiscal, boleto ou comprovante disponível no portal, ou
apenas o status?*

---

## Padrão de acabamento esperado

O portal é avaliado por gerentes de marketing de multinacional. Contam como
defeito reportável, não como implicância:

- formatação inconsistente de valor (`R$ 1.500` vs `1500,00`)
- formatação inconsistente de data (`12/08/2026` vs `2026-08-12`)
- mistura de português e inglês na mesma tela
- rótulos que mudam de nome entre abas para a mesma coisa
- estados vazios sem explicação ("nada aqui" sem dizer o que fazer)
- comportamento diferente no celular

---

## A confirmar com o organizador

- Como um segundo usuário da mesma empresa é criado: pelo próprio patrocinador
  ou só pelo admin?
- O que acontece quando o patrocinador excede o limite da cota — bloqueio, aviso,
  ou aceita e gera cobrança?
- Há prazo de corte por aba? O portal fecha edição depois de uma data?
- O patrocinador consegue exportar a própria lista de participantes?
- Existe registro visível de quando cada dado foi salvo e por qual usuário?
