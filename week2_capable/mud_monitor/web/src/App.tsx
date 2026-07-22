import { Route, Routes } from "react-router";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import HealthPage from "./pages/Health";
import Manager from "./pages/Manager";
import SessionDetail from "./pages/SessionDetail";
import Sessions from "./pages/Sessions";
import Telnet from "./pages/Telnet";

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Dashboard />} />
        <Route path="sessions" element={<Sessions />} />
        <Route path="sessions/:id" element={<SessionDetail />} />
        <Route path="manager" element={<Manager />} />
        <Route path="telnet" element={<Telnet />} />
        <Route path="health" element={<HealthPage />} />
      </Route>
    </Routes>
  );
}
