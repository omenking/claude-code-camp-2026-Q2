import { Link, Outlet } from "react-router";

export default function Layout() {
  return (
    <>
      <header className="topbar">
        <Link to="/" className="brand">
          Mud Monitor
        </Link>
        <nav>
          <Link to="/">Dashboard</Link>
          <Link to="/sessions">Sessions</Link>
          <Link to="/manager">Manager</Link>
          <Link to="/telnet">Telnet</Link>
          <Link to="/health">Health</Link>
        </nav>
      </header>
      <main>
        <Outlet />
      </main>
    </>
  );
}
