# Integrações e ambiente

Nenhuma credencial, chave ou token neste arquivo. Cita-se o nome da variável de
ambiente, nunca o valor.

---

## Sympla — inscrição

Origem dos inscritos do evento. O sistema **consome**; não substitui o Sympla.

- Inscrição entra como pendente de aprovação.
- Aprovação é do organizador. Antes dela, a pessoa não gera contrato, não ocupa
  quarto e não conta em cota.
- O export de participantes do Sympla traz faturamento anual, orçamento de TI,
  número de colaboradores, segmento e autorização de repasse de resultado
  analítico — são esses campos que sustentam a análise de porte usada em mesa
  redonda e curadoria de jantar.

**Gotcha conhecido:** o segmento é declarado pelo próprio inscrito e vem errado
com frequência (houve atacadista cadastrado como "Serviços Públicos"). Regra que
dependa de segmento precisa admitir exceção manual.

*A confirmar: a entrada é por API ou por importação de arquivo? Com que
frequência?*

---

## Autentique — contrato

Geração e assinatura dos contratos.

- O status de assinatura no sistema é **reflexo** do Autentique.
- Em desenvolvimento, contrato roda em modo sandbox. Envio real exige acionamento
  explícito.

**Regra:** nunca disparar contrato real a partir de ambiente de teste. É o erro
mais caro possível aqui — ele chega na caixa de um CIO.

*A confirmar: o retorno de assinatura é webhook ou consulta periódica?*

---

## Resend — e-mail

Envio transacional do sistema.

- Em desenvolvimento e em teste: **modo que monta a mensagem sem enviar**.
- O módulo de cobrança (previsto) usa Resend, sempre com confirmação humana
  antes do disparo.

**Nota de infraestrutura:** as caixas corporativas `@ciocerrado.com.br` ficam na
Skymail, não no Google Workspace, e a rede do escritório bloqueia portas SMTP de
saída em alguns momentos. Isso afeta scripts que enviam por SMTP direto — o
sistema, por usar API, não sofre com isso.

---

## Supabase — banco e autenticação

- Banco no schema `gestao` (ver `70-modelo-de-dados.md`).
- Autenticação por **magic link**, com opção de criar senha.
- RLS sustenta o isolamento entre patrocinadores.

*A confirmar: tempo de validade do magic link e da sessão.*

---

## Netlify — publicação

Base publicada: `https://ciocerrado.netlify.app/gestao/`

**Regra de desenvolvimento:** trabalho em branch separada, nunca direto em
produção.

*A confirmar: existe ambiente de preview/staging separado, ou o evento de teste
dentro da produção faz esse papel?*

---

## App do evento — integração por arquivo

Hoje manual, por dois arquivos exportados (modelo de usuários e modelo de
empresas), importados no app do parceiro.

Regras já estabelecidas do processo:
- registros sem e-mail são excluídos da importação
- o identificador de empresa é conferido contra a lista de empresas já
  cadastradas na plataforma
- registros novos entram ao final do arquivo

Integração automática é **módulo previsto** — ver `60-modulos-previstos.md`. Ela
depende de acordar com o parceiro uma chave de identificação estável.

---

## WhatsApp — API oficial

**Previsto, não disponível.** Depende de verificação da conta WhatsApp Business
e de aprovação de template pela Meta, ambas com prazo de terceiro.

---

## A confirmar com o organizador

- Onde ficam as variáveis de ambiente e quem tem acesso a elas.
- Existe ambiente de staging separado da produção?
- Qual conta/remetente o Resend usa nos envios do sistema.
- Rotina de backup do schema `gestao` e responsável por ela.
