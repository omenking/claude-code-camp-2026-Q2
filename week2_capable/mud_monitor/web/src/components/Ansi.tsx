// Renders `result_html` — HTML the API already escaped and wrapped in ANSI
// spans (api/lib/ansi.rb). Nothing else in the transcript uses
// dangerouslySetInnerHTML; every other field is plain text that React
// escapes on its own.
export default function Ansi({ html }: { html: string }) {
  // eslint-disable-next-line react/no-danger
  return <span dangerouslySetInnerHTML={{ __html: html }} />;
}
