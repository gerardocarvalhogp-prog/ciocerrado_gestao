// Roda uma vez so, na mao, pra gerar o GOOGLE_REFRESH_TOKEN do .env.
// Precisa de GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET ja preenchidos (de
// um OAuth Client ID tipo "Desktop app" no Google Cloud Console, com a
// People API habilitada no projeto) — ver README.md.
//
// USO:  node obter_refresh_token.js
import { google } from "googleapis";
import { createInterface } from "node:readline/promises";
import { config } from "./config.js";

if (!config.google.clientId || !config.google.clientSecret) {
  console.error("Preencha GOOGLE_CLIENT_ID e GOOGLE_CLIENT_SECRET no .env antes de rodar isto.");
  process.exit(1);
}

// "urn:ietf:wg:oauth:2.0:oob" e' o fluxo pra app instalado sem
// servidor web escutando — cola o codigo na mao, sem precisar subir
// nada. Se o Google recusar esse redirect_uri (alguns projetos novos
// exigem um), crie o OAuth Client como "Desktop app" — esse tipo
// aceita "oob" automaticamente.
const REDIRECT = "urn:ietf:wg:oauth:2.0:oob";

const oauth2 = new google.auth.OAuth2(config.google.clientId, config.google.clientSecret, REDIRECT);

const url = oauth2.generateAuthUrl({
  access_type: "offline",   // sem isso, nao vem refresh_token
  prompt: "consent",        // forca reconsentimento mesmo se ja autorizou antes — garante o refresh_token de novo
  scope: ["https://www.googleapis.com/auth/contacts"],
});

console.log("1. Abra esta URL numa conta Google do Workspace do CIO Cerrado (a que vai servir de agenda):\n");
console.log(url);
console.log("\n2. Autorize, copie o código mostrado no final e cole aqui.\n");

const rl = createInterface({ input: process.stdin, output: process.stdout });
const codigo = await rl.question("Código: ");
rl.close();

const { tokens } = await oauth2.getToken(codigo.trim());

if (!tokens.refresh_token) {
  console.error(
    "\nVeio sem refresh_token — provável que essa conta já tinha autorizado este app antes.\n" +
    "Revogue o acesso em https://myaccount.google.com/permissions e rode de novo."
  );
  process.exit(1);
}

console.log("\nGOOGLE_REFRESH_TOKEN=" + tokens.refresh_token);
console.log("\nCola essa linha no .env.");
