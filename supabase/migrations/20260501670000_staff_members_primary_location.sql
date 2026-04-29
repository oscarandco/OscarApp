-- Optional home salon / primary location for each staff member (FK to public.locations).

ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS primary_location_id uuid REFERENCES public.locations(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.staff_members.primary_location_id IS
  'Optional primary (home) location for the staff member; references public.locations.';
