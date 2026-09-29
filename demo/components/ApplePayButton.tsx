import { useState } from "react";
import { Platform, StyleSheet, View } from "react-native";
import { WebView } from "react-native-webview";

// Your backend's Apple Pay routes: see "Backend" in the README.
// Must be on the domain Hesabe registered with Apple for your merchant.
const BASE = "https://yourshop.com/pay/apple-pay";

export type ApplePayResult = { paid: boolean; cancelled?: boolean; reference?: string };

export function ApplePayButton({
  orderId,
  onResult,
}: {
  orderId: string;
  onResult: (result: ApplePayResult) => void;
}) {
  const [attempt, setAttempt] = useState(0); // new key = new WebView = new Hesabe session

  if (Platform.OS !== "ios") return null;

  function intercept(url: string) {
    if (url.startsWith(`${BASE}/done/`)) {
      fetch(url)
        .then((res) => res.json())
        .then(onResult)
        .catch(() => onResult({ paid: false }));
    } else if (url.startsWith(`${BASE}/cancelled`)) {
      onResult({ paid: false, cancelled: true });
    } else {
      return true;
    }
    setAttempt((n) => n + 1);
    return false;
  }

  return (
    <View style={styles.button}>
      <WebView
        key={attempt}
        source={{ uri: `${BASE}/button/${orderId}` }}
        // Apple Pay only works in a WKWebView with no injected scripts;
        // this also disables injectedJavaScript and postMessage.
        enableApplePay
        webviewDebuggingEnabled={__DEV__}
        scrollEnabled={false}
        style={styles.transparent}
        containerStyle={styles.transparent}
        onShouldStartLoadWithRequest={(req) => req.isTopFrame === false || intercept(req.url)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  button: { height: 50, borderRadius: 8, overflow: "hidden" },
  transparent: { backgroundColor: "transparent" },
});
