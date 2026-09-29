import { StatusBar } from "expo-status-bar";
import { useState } from "react";
import { StyleSheet, Text, useColorScheme, View } from "react-native";

import { ApplePayButton, type ApplePayResult } from "./components/ApplePayButton";

// An order that already exists on your backend; the backend reads its amount.
const ORDER = { id: "ORDER-1001", item: "Test item", total: "0.250" };

export default function App() {
  const dark = useColorScheme() === "dark";
  const [result, setResult] = useState<ApplePayResult | null>(null);

  const text = { color: dark ? "#fff" : "#000" };

  return (
    <View style={[styles.container, { backgroundColor: dark ? "#000" : "#f2f2f7" }]}>
      <Text style={[styles.title, text]}>Checkout</Text>

      <View style={[styles.card, { backgroundColor: dark ? "#1c1c1e" : "#fff" }]}>
        <View style={styles.row}>
          <Text style={[styles.body, text]}>{ORDER.item}</Text>
          <Text style={[styles.body, text]}>{ORDER.total} KWD</Text>
        </View>
        <View style={styles.row}>
          <Text style={[styles.total, text]}>Total</Text>
          <Text style={[styles.total, text]}>{ORDER.total} KWD</Text>
        </View>
      </View>

      <ApplePayButton orderId={ORDER.id} onResult={setResult} />

      {result && (
        <Text style={[styles.body, text]}>
          {result.paid ? "Paid" : result.cancelled ? "Cancelled" : "Payment didn't go through"}
        </Text>
      )}
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, paddingTop: 80, paddingHorizontal: 16, gap: 16 },
  title: { fontSize: 34, fontWeight: "700" },
  card: { borderRadius: 12, padding: 16, gap: 12 },
  row: { flexDirection: "row", justifyContent: "space-between" },
  body: { fontSize: 17 },
  total: { fontSize: 17, fontWeight: "600" },
});
