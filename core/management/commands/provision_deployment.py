from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from core.models import Item, Message, Order, PaymentAttempt, SiteSettings, Ticket


class Command(BaseCommand):
    help = "Reset a deployment database and create independent starter content."

    def add_arguments(self, parser):
        parser.add_argument("--type", choices=("artist", "portfolio", "company", "store"), default="artist")
        parser.add_argument("--confirm", required=True, help="Exact deployment name used for the reset confirmation.")

    def handle(self, *args, **options):
        deployment = options["confirm"].strip()
        if not deployment:
            raise CommandError("An exact deployment name is required.")

        with transaction.atomic():
            Ticket.objects.all().delete()
            PaymentAttempt.objects.all().delete()
            Order.objects.all().delete()
            Item.objects.all().delete()
            Message.objects.all().delete()
            SiteSettings.objects.all().delete()
            get_user_model().objects.all().delete()

        call_command("seed", type=options["type"], verbosity=1)
        self.stdout.write(self.style.SUCCESS(
            f"Deployment '{deployment}' is reset with fresh starter content."
        ))
