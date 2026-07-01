import { redirect } from "next/navigation";

export default async function OldReplayPage({
  searchParams,
}: {
  searchParams: Promise<{ id?: string }>;
}) {
  const { id } = await searchParams;
  if (id) redirect(`/replay/${id}`);
  redirect("/");
}
