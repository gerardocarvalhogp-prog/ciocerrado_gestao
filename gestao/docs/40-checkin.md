# Check-in — `checkin.html`

Tela operada no dia do evento. **Não usa `?evento=` na URL** — assume o evento
corrente.

---

## Contexto de uso, que define os requisitos

Quem opera esta tela é staff contratado para o dia: tipicamente uma estudante de
16 anos de Alexânia, que usa bem o celular para redes sociais mas nunca operou
sistema de gestão. Ela não sabe o que é filtro, exportar ou registro, e tem medo
de clicar e estragar. Trabalha **em pé, com fila na frente, sem ninguém para
perguntar.**

Isso não é detalhe de contexto: é a especificação. Toda decisão de design desta
tela responde a uma pergunta só — *ela consegue sozinha, na primeira vez, com
pressa?*

Consequências:

- Busca por nome que funcione com nome parcial e sem acento.
- Ação principal única e óbvia por pessoa encontrada.
- Confirmação visual inequívoca de que o check-in foi registrado.
- Nada destrutivo a um clique de distância.
- Funcionamento pleno no celular, em pé, com uma mão.
- Linguagem sem jargão de sistema.

---

## O que a tela faz

- Localizar a pessoa (CIO, acompanhante, patrocinador, staff).
- Registrar a chegada.
- Mostrar o que o staff precisa saber na hora: quarto, categoria de crachá,
  pendências que impeçam a entrada.

*A confirmar: a tela mostra pendência financeira ou de contrato no momento do
check-in? Se mostra, o staff pode liberar mesmo assim?*

---

## Regras

- Check-in duplicado da mesma pessoa não pode gerar registro duplicado; a tela
  deve avisar que a pessoa já entrou.
- Pessoa não localizada precisa de um caminho — mesmo que seja "chamar o
  organizador". Beco sem saída na fila é falha grave.
- O staff não altera cadastro pela tela de check-in.

*A confirmar: existe modo offline ou tolerância a queda de rede? O sinal em
resort é irregular e a fila não espera.*

---

## Leitura de QR code

**Previsto, não disponível.** Crachá com QR opaco lido pela câmera do celular,
com o mesmo leitor servindo para chegada e para presença por atividade. Ver
`60-modulos-previstos.md`.

Hoje o check-in é por busca de nome.

---

## A confirmar com o organizador

- Como o staff faz login no dia: cada um com o próprio acesso, ou um acesso
  compartilhado no aparelho?
- A tela registra **quem** fez o check-in de cada pessoa?
- Há desfazer para check-in feito por engano, e quem pode usá-lo?
- Comportamento com internet instável.
- O que a tela mostra para acompanhante e para criança.
