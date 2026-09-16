export const questions = [
    ['Do I need API access?', 'Yes. Email api@mobilevikings.be to request access before connecting. Include your name, Mobile Vikings as the brand, VikingBar as the application, and that you want to view your own balance. Wait for their approval and public client ID.'],
    ['Do I need 1Password?', 'No. Sign in directly with your approved public client ID, username, and password. The configured 1Password helper is optional, and no client secret is required.'],
    ['Can anyone download VikingBar?', 'Source code and setup documentation are public under the MIT license. Downloading development builds from GitHub Actions requires a GitHub account. Builds are not Developer ID signed or notarized.'],
    ['Where is the session stored?', 'The refresh session is stored in macOS Keychain.'],
    ['What happens if a refresh fails?', 'The last successful balance stays visible and is marked as out of date.'],
    ['Can I switch between SIMs?', 'Yes. Choose a SIM and then a bundle in the menu. Each SIM keeps its own allowance and extra charges.'],
    ['What does the 30-day chart show?', 'It shows daily SIM data use across bundles. Current-cycle totals stay separate from the clearly labeled estimate. A missing day stays different from a confirmed zero.'],
    ['What account information does VikingBar show?', 'Bills show grouped account totals, a separate unpaid amount, and an explicit PDF action. Viking Points are customer-wide and keep available, pending, and blocked balances separate.'],
    ['Can VikingBar pay an invoice?', 'No. For an eligible unpaid invoice, Bills refreshes the invoice details and generates a bank-transfer QR locally using a bundled helper. No Go installation is needed. You can copy the recipient, IBAN, BIC, and reference individually. You review and authorize the transfer in your banking app. VikingBar does not execute the payment.'],
    ['Which settings are saved?', 'VikingBar saves the used or remaining display choice and refresh interval. It refreshes after your Mac wakes and can launch at login when enabled in Settings.'],
    ['Is VikingBar an official Mobile Vikings app?', 'No. VikingBar is an independent project for Mobile Vikings users.'],
  ];
