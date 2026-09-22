// Deploy as an Auth0 post-login Action and attach it to the Login flow.
// Set the Action secret KC_CLIENT_ID to this application's Client ID.
exports.onExecutePostLogin = async (event, api) => {
  if (event.client.client_id === event.secrets.KC_CLIENT_ID) {
    api.multifactor.enable("any", { allowRememberBrowser: false });
  }
};
