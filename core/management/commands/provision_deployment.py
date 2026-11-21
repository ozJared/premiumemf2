from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from core.models import (
    Item,
    Message,
    Order,
    PaymentAttempt,
    SiteSettings,
    Ticket,
)


class Command(BaseCommand):
    help = "Create fresh starter content in an explicitly named Neon deployment branch."

    def add_arguments(self, parser):
        parser.add_argument("--type", choices=("artist", "portfolio", "company", "store"), default="artist")
        parser.add_argument("--confirm", required=True)

    def handle(self, *args, **options):
        deployment_name = options["confirm"].strip()
        if not deployment_name:
            raise CommandError("A deployment name is required.")

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
            f"Deployment '{deployment_name}' initialized with fresh starter content."
        ))
